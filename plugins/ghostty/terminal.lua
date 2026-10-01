local ffi = require "ffi"
local common = require "core.common"
local runtime = require "plugins.ghostty.runtime"
local config = require "plugins.ghostty.config"
local pty = require "plugins.ghostty.pty"
local Osc = require "plugins.ghostty.osc"
local C, check, sized = runtime.C, runtime.check, runtime.sized

---Owns Ghostty state, encoders, render snapshots, and optional PTY transport.
---@class plugins.ghostty.Terminal
---@field options plugins.ghostty.options
local Terminal = {}
Terminal.__index = Terminal
local instances = setmetatable({}, { __mode = "v" })
local next_id = 0

---@param userdata ffi.cdata Numeric terminal ID stored as a void pointer.
---@return plugins.ghostty.Terminal?
local function instance(userdata)
  return instances[tonumber(ffi.cast("intptr_t", userdata))]
end

-- Shared callbacks avoid exhausting LuaJIT's callback slots after opening tabs.
-- All calls that can invoke them run on the editor thread with JIT disabled.
local callbacks = {

  WRITE_PTY = ffi.cast("GhosttyTerminalWritePtyFn", function(_, ud, data, len)
    local self = instance(ud)
    if self then
      self:write(ffi.string(data, len))
    end
  end),

  BELL = ffi.cast("GhosttyTerminalBellFn", function(_, ud)
    local self = instance(ud)
    if self then
      self:emit { kind = "bell" }
    end
  end),

  SIZE = ffi.cast("GhosttyTerminalSizeFn", function(_, ud, out)
    local self = instance(ud)
    if not self then
      return false
    end
    out.rows, out.columns = self.rows, self.cols
    out.cell_width, out.cell_height = self.cell_width, self.cell_height
    return true
  end),

  COLOR_SCHEME = ffi.cast("GhosttyTerminalColorSchemeFn", function(_, ud, out)
    local self = instance(ud)
    local bg = self and self.options.background or { 0, 0, 0 }
    out[0] = (bg[1] + bg[2] + bg[3] > 384) and C.GHOSTTY_COLOR_SCHEME_LIGHT
      or C.GHOSTTY_COLOR_SCHEME_DARK
    return true
  end),

  DEVICE_ATTRIBUTES = ffi.cast(
    "GhosttyTerminalDeviceAttributesFn",
    function(_, _, out)
      ffi.fill(out, ffi.sizeof("GhosttyDeviceAttributes"))
      out.primary.conformance_level = 62 -- VT220, ANSI color, selective erase.
      out.primary.features[0], out.primary.features[1] = 22, 6
      out.primary.num_features = 2
      out.secondary.device_type, out.secondary.firmware_version = 1, 1
      return true
    end
  ),
}

local resources = {
  { "terminal", "GhosttyTerminal", "terminal" },
  { "render", "GhosttyRenderState", "render_state" },
  { "iterator", "GhosttyRenderStateRowIterator", "render_state_row_iterator" },
  { "cells", "GhosttyRenderStateRowCells", "render_state_row_cells" },
  { "key_encoder", "GhosttyKeyEncoder", "key_encoder" },
  { "key_event", "GhosttyKeyEvent", "key_event" },
  { "mouse_encoder", "GhosttyMouseEncoder", "mouse_encoder" },
  { "mouse_event", "GhosttyMouseEvent", "mouse_event" },
}

---@param value? number|string
---@param default integer
---@return integer Dimension clamped to the VT API's unsigned 16-bit range.
local function dimension(value, default)
  return common.clamp(math.floor(tonumber(value) or default), 1, 65535)
end

---Create native terminal resources and optionally start a child process.
---@param options? plugins.ghostty.options
---@return plugins.ghostty.Terminal
function Terminal.new(options)
  options = options or {}
  local self = setmetatable({
    options = options,
    events = {},
    dirty = true,
    writes = {},
    write_head = 1,
    write_tail = 0,
    write_offset = 0,
    pending_bytes = 0,
    cols = dimension(options.cols, 80),
    rows = dimension(options.rows, 24),
    cell_width = dimension(options.cell_width, 8),
    cell_height = dimension(options.cell_height, 16),
  }, Terminal)
  next_id = next_id + 1
  self.id, instances[next_id] = next_id, self

  local ok, err = pcall(function()
    for _, entry in ipairs(resources) do
      local out = ffi.new(entry[2] .. "[1]")
      if entry[1] == "terminal" then
        check(
          C.ghostty_terminal_new(nil, out, self.cols, self.rows),
          "create terminal"
        )
      else
        check(
          C["ghostty_" .. entry[3] .. "_new"](nil, out),
          "create " .. entry[1]
        )
      end
      self[entry[1]] = ffi.gc(out[0], C["ghostty_" .. entry[3] .. "_free"])
    end
    check(
      C.ghostty_terminal_set(
        self.terminal,
        C.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES,
        ffi.new("size_t[1]", options.max_scrollback or config.max_scrollback)
      )
    )
    check(
      C.ghostty_terminal_set(
        self.terminal,
        C.GHOSTTY_TERMINAL_OPT_USERDATA,
        ffi.cast("void *", self.id)
      )
    )
    for name, callback in pairs(callbacks) do
      check(
        C.ghostty_terminal_set(
          self.terminal,
          C["GHOSTTY_TERMINAL_OPT_" .. name],
          callback
        )
      )
    end
    local zero = ffi.new("uint64_t[1]")
    check(
      C.ghostty_terminal_set(
        self.terminal,
        C.GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT,
        zero
      )
    )
    self:set_colors(options.foreground, options.background, options.cursor)
    if options.palette then
      self:set_palette(options.palette)
    end
    self.read_buffer = ffi.new("uint8_t[16384]")
    self.osc = Osc.new(
      options.osc_max_bytes or config.osc_max_bytes,
      function(event)
        if event.kind == "cwd-changed" then
          local value =
            ffi.new("GhosttyString", { ptr = event.cwd, len = #event.cwd })
          check(
            C.ghostty_terminal_set(
              self.terminal,
              C.GHOSTTY_TERMINAL_OPT_PWD,
              value
            )
          )
        -- poll_events emits the state change once, after the full read batch.
        else
          self:emit(event)
        end
      end
    )
    if options.command ~= false then
      local spawn =
        common.merge(options, { cols = self.cols, rows = self.rows })
      local handle, message = pty.new(spawn)
      if not handle then
        error("Cannot start terminal: " .. message)
      end
      self.pty = handle
    end
    self:resize(self.cols, self.rows, self.cell_width, self.cell_height)
  end)

  if not ok then
    self:close()
    error(err, 2)
  end
  return self
end

function Terminal:emit(event)
  if #self.events < 256 then
    self.events[#self.events + 1] = event
  end
end

---Release resources once, detaching finalizers before freeing native objects.
function Terminal:close()
  if self.closed then
    return
  end
  self.closed = true
  instances[self.id] = nil
  if self.pty then
    pty.C.pgt_pty_close(ffi.gc(self.pty, nil))
    self.pty = nil
  end
  for i = #resources, 1, -1 do
    local entry = resources[i]
    if self[entry[1]] then
      C["ghostty_" .. entry[3] .. "_free"](ffi.gc(self[entry[1]], nil))
      self[entry[1]] = nil
    end
  end
  self.writes, self.pending_bytes = {}, 0
end

function Terminal:set_colors(foreground, background, cursor)
  if self.closed then
    return
  end
  for name, color in pairs {
    FOREGROUND = foreground,
    BACKGROUND = background,
    CURSOR = cursor,
  } do
    check(
      C.ghostty_terminal_set(
        self.terminal,
        C["GHOSTTY_TERMINAL_OPT_COLOR_" .. name],
        ffi.new("GhosttyColorRgb[1]", { { color[1], color[2], color[3] } })
      )
    )
    self.options[name:lower()] = color
  end
  self.dirty = true
end

---Replace ANSI defaults while preserving extended colors and OSC overrides.
---@param palette integer[][] Sixteen RGB colors, indexed from one.
function Terminal:set_palette(palette)
  if self.closed then
    return
  end
  assert(#palette == 16, "Expected sixteen ANSI colors")
  local colors = ffi.new("GhosttyColorRgb[256]")
  -- Keep the standard color cube and grayscale ramp. Reading defaults also
  -- keeps application OSC overrides separate from our theme-derived defaults.
  check(
    C.ghostty_terminal_get(
      self.terminal,
      C.GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT,
      colors
    )
  )
  for i = 1, 16 do
    colors[i - 1].r, colors[i - 1].g, colors[i - 1].b =
      palette[i][1], palette[i][2], palette[i][3]
  end
  check(
    C.ghostty_terminal_set(
      self.terminal,
      C.GHOSTTY_TERMINAL_OPT_COLOR_PALETTE,
      colors
    )
  )
  self.dirty = true
end

---Resize the emulated grid and PTY; cell dimensions are measured in pixels.
---@param cols integer
---@param rows integer
---@param cw integer
---@param ch integer
---@return boolean
function Terminal:resize(cols, rows, cw, ch)
  if self.closed then
    return false
  end
  self.cols, self.rows = dimension(cols, 80), dimension(rows, 24)
  self.cell_width, self.cell_height = dimension(cw, 8), dimension(ch, 16)
  check(
    C.ghostty_terminal_resize(
      self.terminal,
      self.cols,
      self.rows,
      self.cell_width,
      self.cell_height
    )
  )
  if self.pty then
    pty.C.pgt_pty_resize(
      self.pty,
      self.cols,
      self.rows,
      math.min(65535, self.cols * self.cell_width),
      math.min(65535, self.rows * self.cell_height)
    )
  end
  self.snapshot, self.dirty = nil, true
  return true
end

---Queue bytes for the child, respecting the configured input queue limit.
---@param data string
---@return boolean accepted
---@return string? reason
function Terminal:write(data)
  if self.closed or self.exit_code or self.eof then
    return false, "Terminal has exited"
  end
  if #data == 0 then
    return true
  end
  if
    self.pending_bytes + #data
    > (self.options.write_limit or config.write_limit)
  then
    self:emit { kind = "error", text = "Terminal input queue is full" }
    return false, "Terminal input queue is full"
  end
  self.write_tail = self.write_tail + 1
  self.writes[self.write_tail] = data
  self.pending_bytes = self.pending_bytes + #data
  return true
end

function Terminal:flush()
  if not self.pty or self.closed then
    return
  end
  local budget = self.options.read_budget or config.read_budget
  while self.write_head <= self.write_tail and budget > 0 do
    local data = self.writes[self.write_head]
    local count = tonumber(
      pty.C.pgt_pty_write(
        self.pty,
        ffi.cast("const uint8_t *", data) + self.write_offset,
        math.min(budget, #data - self.write_offset)
      )
    )
    if count == -2 or count == 0 then
      break
    end
    if count < 0 then
      self.writes, self.write_head, self.write_tail = {}, 1, 0
      self.write_offset, self.pending_bytes = 0, 0
      break
    end
    self.write_offset, self.pending_bytes, budget =
      self.write_offset + count, self.pending_bytes - count, budget - count
    if self.write_offset == #data then
      self.writes[self.write_head] = nil
      self.write_head, self.write_offset = self.write_head + 1, 0
    end
  end
  if self.write_head > self.write_tail then
    self.write_head, self.write_tail = 1, 0
  end
end

---Consume raw process output; Ghostty may call back into Lua during this call.
---@param data string
function Terminal:feed(data)
  if self.closed or #data == 0 then
    return
  end
  self.osc:feed(data)
  C.ghostty_terminal_vt_write(self.terminal, data, #data)
  self.dirty = true
end

function Terminal:state_string(key)
  local value = ffi.new("GhosttyString[1]")
  if
    C.ghostty_terminal_get(self.terminal, key, value) == 0
    and value[0].ptr ~= nil
  then
    return ffi.string(value[0].ptr, value[0].len)
  end
end

---Flush input, read bounded output, reap children, and drain pending events.
---@return table[] events
function Terminal:poll_events()
  pty.C.pgt_pty_reap()
  if self.closed then
    return {}
  end
  self:flush()
  if self.pty then
    local budget = self.options.read_budget or config.read_budget
    while budget > 0 and not self.eof do
      local count = tonumber(
        pty.C.pgt_pty_read(self.pty, self.read_buffer, math.min(16384, budget))
      )
      if count == -2 then
        break
      end
      if count <= 0 then
        self.eof = true
        break
      end
      self:feed(ffi.string(self.read_buffer, count))
      budget = budget - count
    end
    self:flush()
    -- Drain the final PTY output before announcing exit.
    if not self.exit_code and budget > 0 then
      local code, signal = ffi.new("int[1]"), ffi.new("int[1]")
      if pty.C.pgt_pty_poll(self.pty, code, signal) == 1 then
        self.exit_code, self.exit_signal =
          tonumber(code[0]), tonumber(signal[0])
        self:emit {
          kind = "terminal-exited",
          code = self.exit_code,
          signal = self.exit_signal,
        }
      end
    end
  end
  local title, cwd =
    self:state_string(C.GHOSTTY_TERMINAL_DATA_TITLE),
    self:state_string(C.GHOSTTY_TERMINAL_DATA_PWD)
  if title and title ~= "" and title ~= self.last_title then
    self.last_title = title
    self:emit { kind = "title-changed", title = title }
  end
  if cwd and cwd ~= "" and cwd ~= self.last_cwd then
    self.last_cwd = cwd
    self:emit { kind = "cwd-changed", cwd = cwd }
  end
  local events = self.events
  self.events = {}
  return events
end

function Terminal:exited()
  return self.exit_code ~= nil, self.exit_code, self.exit_signal
end

function Terminal:is_dirty()
  return self.dirty
end

function Terminal:clear_dirty()
  self.dirty = false
end

function Terminal:mode(number)
  if self.closed then
    return false
  end
  local value = ffi.new("GhosttyTerminalModeConfig", { mode = number })
  return C.ghostty_terminal_get(
    self.terminal,
    C.GHOSTTY_TERMINAL_DATA_MODE,
    value
  ) == 0 and value.value
end

function Terminal:bracketed_paste()
  return self:mode(2004)
end

function Terminal:mouse_tracking()
  if self.closed then
    return false
  end
  local value = ffi.new("bool[1]")
  return C.ghostty_terminal_get(
    self.terminal,
    C.GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING,
    value
  ) == 0 and value[0]
end

function Terminal:focus(focused)
  if self:mode(1004) then
    self:write(focused and "\27[I" or "\27[O")
  end
end

function Terminal:scroll(delta)
  if self.closed then
    return
  end
  local value = ffi.new("GhosttyTerminalScrollViewport")
  value.tag, value.value.delta = C.GHOSTTY_SCROLL_VIEWPORT_DELTA, delta
  C.ghostty_terminal_scroll_viewport(self.terminal, value)
  self.dirty = true
end

---Scroll to a zero-based row from the top of the active screen's history.
---@param row integer Ghostty clamps rows beyond the end to the bottom.
function Terminal:scroll_to(row)
  if self.closed then
    return
  end
  local value = ffi.new("GhosttyTerminalScrollViewport")
  value.tag = C.GHOSTTY_SCROLL_VIEWPORT_ROW
  value.value.row = math.max(0, math.floor(row))
  C.ghostty_terminal_scroll_viewport(self.terminal, value)
  self.dirty = true
end

function Terminal:scroll_bottom()
  if self.closed then
    return
  end
  C.ghostty_terminal_scroll_viewport(
    self.terminal,
    ffi.new(
      "GhosttyTerminalScrollViewport",
      { tag = C.GHOSTTY_SCROLL_VIEWPORT_BOTTOM }
    )
  )
  self.dirty = true
end

function Terminal:input_text(text)
  self:scroll_bottom()
  return self:write(text)
end

---Encode paste for the active mode; unsafe text needs explicit confirmation.
---@param text string
---@param force? boolean Allow control characters and multiple lines.
---@return boolean accepted
---@return string? reason
function Terminal:paste(text, force)
  if self.closed then
    return false
  end
  local safe = C.ghostty_paste_is_safe(text, #text)
  if not safe and not force then
    return false, "unsafe"
  end
  local data = ffi.new("char[?]", #text + 1, text)
  local out, length = ffi.new("char[?]", #text + 32), ffi.new("size_t[1]")
  check(
    C.ghostty_paste_encode(
      data,
      #text,
      self:bracketed_paste(),
      out,
      #text + 32,
      length
    )
  )
  return self:input_text(ffi.string(out, length[0]))
end

local key_names = {
  ["return"] = "ENTER",
  enter = "ENTER",
  ["keypad enter"] = "NUMPAD_ENTER",
  up = "ARROW_UP",
  down = "ARROW_DOWN",
  left = "ARROW_LEFT",
  right = "ARROW_RIGHT",
  pageup = "PAGE_UP",
  pagedown = "PAGE_DOWN",
  space = "SPACE",
  [" "] = "SPACE",
  ["`"] = "BACKQUOTE",
  ["-"] = "MINUS",
  ["="] = "EQUAL",
  ["["] = "BRACKET_LEFT",
  ["]"] = "BRACKET_RIGHT",
  ["\\"] = "BACKSLASH",
  [";"] = "SEMICOLON",
  ["'"] = "QUOTE",
  [","] = "COMMA",
  ["."] = "PERIOD",
  ["/"] = "SLASH",
}

---@param value? table<string, boolean> Pragtical modifier states.
---@return integer Ghostty modifier mask.
local function mods(value)
  value = value or {}
  return (value.shift and 1 or 0)
    + (value.ctrl and 2 or 0)
    + ((value.alt or value.option) and 4 or 0)
    + (value.cmd and 8 or 0)
end

---Encode a Pragtical key event, including repeats and consumed modifiers.
---@param event table Key, text, modifiers, and optional repeat/release flags.
---@return boolean handled
function Terminal:send_key(event)
  if self.closed then
    return false
  end
  local name = key_names[event.key]
    or (event.key:match("^%d$") and "DIGIT_" .. event.key)
    or event.key:upper()

  local ok, key = pcall(function()
    return C["GHOSTTY_KEY_" .. name]
  end)

  if not ok then
    return false
  end
  C.ghostty_key_encoder_setopt_from_terminal(self.key_encoder, self.terminal)
  if self.options.mac_option_as_meta ~= false then
    C.ghostty_key_encoder_setopt(
      self.key_encoder,
      C.GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT,
      ffi.new("int[1]", C.GHOSTTY_OPTION_AS_ALT_TRUE)
    )
  end
  C.ghostty_key_event_set_key(self.key_event, key)
  C.ghostty_key_event_set_action(
    self.key_event,
    event.released and C.GHOSTTY_KEY_ACTION_RELEASE
      or (
        event.repeated and C.GHOSTTY_KEY_ACTION_REPEAT
        or C.GHOSTTY_KEY_ACTION_PRESS
      )
  )
  C.ghostty_key_event_set_mods(self.key_event, mods(event.mods))
  C.ghostty_key_event_set_consumed_mods(
    self.key_event,
    mods(event.consumed_mods)
  )
  -- Pragtical names the Space key "space". Kitty needs its codepoint to
  -- encode releases as key events instead of falling back to another space.
  local unshifted = event.key == "space" and " " or event.key
  C.ghostty_key_event_set_unshifted_codepoint(
    self.key_event,
    #unshifted == 1 and unshifted:byte() or 0
  )
  local text = event.text or ""
  -- The event borrows this pointer; FFI does not keep Lua strings alive for C.
  self.key_text = text
  C.ghostty_key_event_set_utf8(self.key_event, text, #text)
  local out, length = ffi.new("char[256]"), ffi.new("size_t[1]")
  check(
    C.ghostty_key_encoder_encode(
      self.key_encoder,
      self.key_event,
      out,
      256,
      length
    )
  )
  if length[0] == 0 then
    return event.released == true
  end
  if not event.released then
    self:scroll_bottom()
  end
  return self:write(ffi.string(out, length[0]))
end

local buttons = {
  left = 1,
  right = 2,
  middle = 3,
  wheel_up = 4,
  wheel_down = 5,
}

---Encode a mouse event, including drags beyond the visible cell grid.
---@param event table Action, held button, pixel position, and modifiers.
---@return boolean queued
function Terminal:send_mouse(event)
  if self.closed then
    return false
  end
  C.ghostty_mouse_encoder_setopt_from_terminal(
    self.mouse_encoder,
    self.terminal
  )
  local size = sized("GhosttyMouseEncoderSize")
  size.screen_width, size.screen_height =
    self.cols * self.cell_width, self.rows * self.cell_height
  size.cell_width, size.cell_height = self.cell_width, self.cell_height
  C.ghostty_mouse_encoder_setopt(
    self.mouse_encoder,
    C.GHOSTTY_MOUSE_ENCODER_OPT_SIZE,
    size
  )
  local button = buttons[event.button]
  local pressed = ffi.new(
    "bool[1]",
    button ~= nil and button <= 3 and event.action ~= "release"
  )
  C.ghostty_mouse_encoder_setopt(
    self.mouse_encoder,
    C.GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED,
    pressed
  )
  C.ghostty_mouse_event_set_action(
    self.mouse_event,
    C["GHOSTTY_MOUSE_ACTION_" .. (event.action or "press"):upper()]
  )
  if button then
    C.ghostty_mouse_event_set_button(self.mouse_event, button)
  else
    C.ghostty_mouse_event_clear_button(self.mouse_event)
  end
  C.ghostty_mouse_event_set_mods(self.mouse_event, mods(event.mods))
  C.ghostty_mouse_event_set_position(
    self.mouse_event,
    ffi.new("GhosttyMousePosition", { event.x or 0, event.y or 0 })
  )
  local out, length = ffi.new("char[256]"), ffi.new("size_t[1]")
  check(
    C.ghostty_mouse_encoder_encode(
      self.mouse_encoder,
      self.mouse_event,
      out,
      256,
      length
    )
  )
  return length[0] > 0 and self:write(ffi.string(out, length[0]))
end

---@param col integer One-based viewport column.
---@param row integer One-based viewport row.
---@return ffi.cdata GhosttyPoint with zero-based coordinates.
local function point(col, row)
  local p = ffi.new("GhosttyPoint")
  p.tag = C.GHOSTTY_POINT_TAG_VIEWPORT
  p.value.coordinate.x, p.value.coordinate.y = col - 1, row - 1
  return p
end

---Find Ghostty's word bounds, clipped to the visible viewport.
---@param col integer One-based viewport column.
---@param row integer One-based viewport row.
---@return table? first Inclusive one-based row and column.
---@return table? last Inclusive one-based row and column.
function Terminal:word_range(col, row)
  if self.closed then
    return
  end
  local options = sized("GhosttyTerminalSelectWordOptions")
  options.ref.size = ffi.sizeof("GhosttyGridRef")
  if
    C.ghostty_terminal_grid_ref(self.terminal, point(col, row), options.ref)
      ~= 0
  then
    return
  end
  local selected = sized("GhosttySelection")
  local result = C.ghostty_terminal_select_word(
    self.terminal, options, selected
  )
  if result == C.GHOSTTY_NO_VALUE then
    return
  end
  check(result)
  local bounds, coord = {}, ffi.new("GhosttyPointCoordinate")
  for i = 1, 2 do
    result = C.ghostty_terminal_point_from_grid_ref(
      self.terminal,
      selected[i == 1 and "start" or "end"],
      C.GHOSTTY_POINT_TAG_VIEWPORT,
      coord
    )
    if result == C.GHOSTTY_NO_VALUE then
      bounds[i] = { col = 1, row = 1 } -- Above the viewport.
    else
      check(result)
      bounds[i] = coord.y >= self.rows
          and { col = self.cols, row = self.rows }
        or { col = tonumber(coord.x) + 1, row = tonumber(coord.y) + 1 }
    end
  end
  return bounds[1], bounds[2]
end

---Format an inclusive selection using one-based viewport cell coordinates.
---@return string? text
function Terminal:copy_selection(c1, r1, c2, r2)
  if self.closed then
    return
  end
  -- Keep the selection rooted while the formatter holds its C pointer.
  self.selection_buffer = self.selection_buffer or sized("GhosttySelection")
  local selection = self.selection_buffer
  selection.start.size, selection["end"].size =
    ffi.sizeof("GhosttyGridRef"), ffi.sizeof("GhosttyGridRef")
  if
    C.ghostty_terminal_grid_ref(self.terminal, point(c1, r1), selection.start)
      ~= 0
    or C.ghostty_terminal_grid_ref(
        self.terminal,
        point(c2, r2),
        selection["end"]
      )
      ~= 0
  then
    return
  end
  local options = sized("GhosttyFormatterTerminalOptions")
  options.emit, options.trim, options.unwrap =
    C.GHOSTTY_FORMATTER_FORMAT_PLAIN, true, true
  options.extra.size, options.extra.screen.size =
    ffi.sizeof("GhosttyFormatterTerminalExtra"),
    ffi.sizeof("GhosttyFormatterScreenExtra")
  options.selection = selection
  local out = ffi.new("GhosttyFormatter[1]")
  check(C.ghostty_formatter_terminal_new(nil, out, self.terminal, options))
  local formatter = ffi.gc(out[0], C.ghostty_formatter_free)
  local length = ffi.new("size_t[1]")
  C.ghostty_formatter_format_buf(formatter, nil, 0, length)
  local buffer = ffi.new("uint8_t[?]", math.max(1, tonumber(length[0])))
  check(C.ghostty_formatter_format_buf(formatter, buffer, length[0], length))
  C.ghostty_formatter_free(ffi.gc(formatter, nil))
  return ffi.string(buffer, length[0])
end

---Return the OSC 8 link at a one-based viewport cell, if present.
---@param col integer
---@param row integer
---@return string? uri
function Terminal:hyperlink_at(col, row)
  if self.closed then
    return
  end
  local ref, length = sized("GhosttyGridRef"), ffi.new("size_t[1]")
  if C.ghostty_terminal_grid_ref(self.terminal, point(col, row), ref) ~= 0 then
    return
  end
  C.ghostty_grid_ref_hyperlink_uri(ref, nil, 0, length)
  if length[0] == 0 then
    return
  end
  local buffer = ffi.new("char[?]", length[0])
  check(C.ghostty_grid_ref_hyperlink_uri(ref, buffer, length[0], length))
  return ffi.string(buffer, length[0])
end

-- Snapshots share immutable colors; unused truecolors can be collected.
local render_colors = setmetatable({}, { __mode = "v" })

---@param r integer
---@param g integer
---@param b integer
---@return integer[] Shared opaque RGBA color; callers must not mutate it.
local function render_color(r, g, b)
  local key = r * 65536 + g * 256 + b
  local color = render_colors[key]
  if not color then
    color = { r, g, b, 255 }
    render_colors[key] = color
  end
  return color
end

---@param value ffi.cdata GhosttyColorRgb struct.
---@return integer[] Shared opaque RGBA color for Pragtical's renderer.
local function rgb(value)
  return render_color(tonumber(value.r), tonumber(value.g), tonumber(value.b))
end

---Build a snapshot with shared immutable rows, cells and colors.
---Dirty rows are checked for identical cells because TUIs often repaint them.
---@return table? snapshot
function Terminal:update_render()
  if self.closed then
    return
  end
  check(C.ghostty_render_state_update(self.render, self.terminal))
  local colors = sized("GhosttyRenderStateColors")
  check(
    C.ghostty_render_state_get(
      self.render,
      C.GHOSTTY_RENDER_STATE_DATA_COLORS,
      colors
    )
  )
  local snapshot = {
    cols = self.cols,
    rows = self.rows,
    rows_data = {},
    background = rgb(colors.background),
    foreground = rgb(colors.foreground),
  }

  ---@param key string Render-state query suffix.
  ---@param ctype string C output type for this query.
  ---@return number|boolean|ffi.cdata
  local function get(key, ctype)
    local out = ffi.new(ctype .. "[1]")
    check(
      C.ghostty_render_state_get(
        self.render,
        C["GHOSTTY_RENDER_STATE_DATA_" .. key],
        out
      )
    )
    return out[0]
  end

  snapshot.cursor = {
    visible = get("CURSOR_VISIBLE", "bool")
      and get("CURSOR_VIEWPORT_HAS_VALUE", "bool"),
    color = colors.cursor_has_value and rgb(colors.cursor) or nil,
  }
  if snapshot.cursor.visible then
    snapshot.cursor.x, snapshot.cursor.y =
      tonumber(get("CURSOR_VIEWPORT_X", "uint16_t")),
      tonumber(get("CURSOR_VIEWPORT_Y", "uint16_t"))
    snapshot.cursor.shape = tonumber(get("CURSOR_VISUAL_STYLE", "int"))
  end
  local scrollbar = ffi.new("GhosttyTerminalScrollbar[1]")
  check(
    C.ghostty_terminal_get(
      self.terminal,
      C.GHOSTTY_TERMINAL_DATA_SCROLLBAR,
      scrollbar
    )
  )
  snapshot.scrollbar = {
    total = tonumber(scrollbar[0].total),
    offset = tonumber(scrollbar[0].offset),
    len = tonumber(scrollbar[0].len),
  }
  local iterator = ffi.new("GhosttyRenderStateRowIterator[1]", self.iterator)
  check(
    C.ghostty_render_state_get(
      self.render,
      C.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
      iterator
    )
  )
  local cells = ffi.new("GhosttyRenderStateRowCells[1]", self.cells)
  local style = sized("GhosttyStyle")
  local fg, bg = ffi.new("GhosttyColorRgb[1]"), ffi.new("GhosttyColorRgb[1]")
  local raw, wide = ffi.new("GhosttyCellsView"), ffi.new("int[1]")
  local chars = ffi.new("uint8_t[64]")
  local buffer =
    ffi.new("GhosttyBuffer", { ptr = chars, cap = ffi.sizeof(chars) })
  local keys = ffi.new("GhosttyRenderStateRowCellsData[2]", {
    C.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE,
    C.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8,
  })
  -- The locals above own the memory referenced by this pointer array.
  local values = ffi.new("void *[2]", { style, buffer })
  local clean, row_dirty = ffi.new("bool[1]"), ffi.new("bool[1]")
  local row_index = 0
  while C.ghostty_render_state_row_iterator_next(self.iterator) do
    row_index = row_index + 1
    check(
      C.ghostty_render_state_row_get(
        self.iterator,
        C.GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY,
        row_dirty
      )
    )
    local previous = self.snapshot and self.snapshot.rows_data[row_index]
    if previous and not row_dirty[0] then
      snapshot.rows_data[row_index] = previous
    else
      local row, col = { spans = {}, cells = {} }, 0
      local unchanged = previous ~= nil
      check(
        C.ghostty_render_state_row_get(
          self.iterator,
          C.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
          cells
        )
      )
      -- Borrow the entire row only until the next render-state update.
      check(
        C.ghostty_render_state_row_get(
          self.iterator,
          C.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS_RAW,
          raw
        )
      )
      while C.ghostty_render_state_row_cells_next(self.cells) do
        check(C.ghostty_cell_get(raw.ptr[col], C.GHOSTTY_CELL_DATA_WIDE, wide))
        local width = wide[0] == C.GHOSTTY_CELL_WIDE_WIDE and 2 or 1
        if wide[0] ~= C.GHOSTTY_CELL_WIDE_SPACER_TAIL then
          local result = C.ghostty_render_state_row_cells_get_multi(
            self.cells,
            2,
            keys,
            values,
            nil
          )
          if result == C.GHOSTTY_OUT_OF_SPACE then
            chars = ffi.new("uint8_t[?]", buffer.len)
            buffer.ptr, buffer.cap = chars, ffi.sizeof(chars)
            result = C.ghostty_render_state_row_cells_get(
              self.cells,
              C.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8,
              buffer
            )
          end
          check(result)
          local text = buffer.len > 0 and ffi.string(chars, buffer.len) or " "
          fg[0], bg[0] = colors.foreground, colors.background
          -- A default color returns INVALID_VALUE. Keep these separate:
          -- get_multi stops at the first absent optional value.
          C.ghostty_render_state_row_cells_get(
            self.cells,
            C.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR,
            fg
          )
          C.ghostty_render_state_row_cells_get(
            self.cells,
            C.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR,
            bg
          )
          local fore, back = rgb(fg[0]), rgb(bg[0])
          if style.inverse then
            fore, back = back, fore
          end
          if style.invisible then
            fore = back
          end
          if style.faint then
            fore = render_color(
              math.floor((fore[1] + back[1]) / 2),
              math.floor((fore[2] + back[2]) / 2),
              math.floor((fore[3] + back[3]) / 2)
            )
          end
          local index = #row.spans + 1
          local old = previous and previous.spans[index]
          local same = old
            and old.x == col
            and old.width == width
            and old.text == text
            and old.fg == fore
            and old.bg == back
            and old.bold == style.bold
            and old.italic == style.italic
            and old.underline == (style.underline ~= 0)
            and old.strikethrough == style.strikethrough
          row.spans[index] = same and old
            or {
              x = col,
              width = width,
              text = text,
              fg = fore,
              bg = back,
              bold = style.bold,
              italic = style.italic,
              underline = style.underline ~= 0,
              strikethrough = style.strikethrough,
            }
          unchanged = unchanged and same
          row.cells[col + 1] = text
        else
          row.cells[col + 1] = ""
        end
        col = col + 1
      end
      snapshot.rows_data[row_index] = unchanged
          and #previous.cells == col
          and #previous.spans == #row.spans
          and previous
        or row
    end
    check(
      C.ghostty_render_state_row_set(
        self.iterator,
        C.GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY,
        clean
      )
    )
  end
  check(
    C.ghostty_render_state_set(
      self.render,
      C.GHOSTTY_RENDER_STATE_OPTION_DIRTY,
      ffi.new("int[1]", C.GHOSTTY_RENDER_STATE_DIRTY_FALSE)
    )
  )
  self.snapshot = snapshot
  return snapshot
end

jit.off(Terminal.feed, true)
jit.off(Terminal.resize, true)

return {
  new = Terminal.new,
  Terminal = Terminal,
  runtime = runtime.path,
  reap = pty.C.pgt_pty_reap,
}
