-- mod-version:3
local core = require "core"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local common = require "core.common"
local View = require "core.view"
local renderer = require "renderer"
local system = require "system"
local defaults = require "plugins.ghostty.config"
local events = require "plugins.ghostty.events"
local selection = require "plugins.ghostty.selection"
local click = require "plugins.ghostty.click_to_open"
local shell = require "plugins.ghostty.shell"
local palette = require "plugins.ghostty.palette"

-- Resolve the runtime lazily so missing binaries do not break editor startup.
local backend

---Load the FFI backend on demand so missing libraries do not break startup.
---@return table
local function get_backend()
  if not backend then
    backend = require "plugins.ghostty.terminal"
  end
  return backend
end

local views = setmetatable({}, { __mode = "k" })
local drawer, drawer_node, drawer_hidden, previous_view
---Editor view for a terminal tab or the shared bottom drawer.
---@class plugins.ghostty.TerminalView : core.view
---@field terminal? plugins.ghostty.Terminal
---@field options plugins.ghostty.options
local TerminalView = View:extend()
TerminalView.context = "session"

---@param view plugins.ghostty.TerminalView
local function close_view(view)
  local root = core.root_view.root_node
  local node = root:get_node_for_view(view)
  if node then
    node:close_view(root, view)
  else
    view:close()
  end
end

---Create a terminal view; open_tab or open_drawer attaches it to the editor.
---@param options? plugins.ghostty.options
function TerminalView:new(options)
  TerminalView.super.new(self)
  -- Ghostty scrolls by rows; keep View's pixel scrolling disabled.
  self.scrollback_rows = 0
  self.scrollbar_visible = false
  self.ghostty_terminal_view = true
  self.options = common.merge(config.plugins.ghostty, options or {})
  self.title = self.options.title or "Terminal"
  self.cwd = self.options.cwd or (core.root_project() or {}).path
  self.selection = selection.new()
  self.pressed = {}
  self.close_on_exit = (options and options.close_on_exit)
    or (self.options.kind == "agent" and self.options.agent_close_on_exit)
    or self.options.close_on_exit
  local spawn = common.merge(self.options, {
    cwd = self.cwd,
    foreground = self.options.foreground or style.text,
    background = self.options.background or style.background,
    cursor = self.options.cursor or style.caret,
  })
  self.palette_key =
    palette.signature(style, spawn.foreground, spawn.background)
  spawn.palette = palette.generate(style, spawn.foreground, spawn.background)
  if self.options.terminfo then
    spawn.env =
      common.merge(spawn.env or {}, { TERMINFO = self.options.terminfo })
  end
  self.terminal = get_backend().new(spawn)
  views[self] = true
  events.emit("terminal-created", { view = self, terminal = self.terminal })
end

function TerminalView:get_name()
  return self.title
end

function TerminalView:supports_text_input()
  return true
end

function TerminalView:set_target_size(axis, value)
  self.size[axis] = math.max(0, value)
  return true
end

---Release this session's process and native handles; safe to call repeatedly.
function TerminalView:close()
  views[self] = nil
  self.scrollbar_pressed = false
  self.v_scrollbar.dragging = false
  if self.terminal then
    local terminal = self.terminal
    self.terminal = nil
    terminal:close()
    events.emit("terminal-closed", { view = self, terminal = terminal })
  end
  if drawer == self then
    drawer, drawer_node, drawer_hidden = nil, nil, nil
  end
  self:update_scrollbar()
end

function TerminalView:try_close(do_close)
  self:close()
  do_close()
end

---@param view plugins.ghostty.TerminalView
---@param event table
local function handle_event(view, event)
  event.view, event.terminal = view, view.terminal
  if event.kind == "title-changed" then
    view.title = event.title ~= "" and event.title or "Terminal"
    core.redraw = true
  elseif event.kind == "cwd-changed" then
    event.previous_cwd, view.cwd =
      view.cwd, click.decode_file_uri(event.cwd) or event.cwd
    event.cwd = view.cwd
  elseif event.kind == "terminal-exited" then
    view.exited, view.exit_code, view.exit_signal =
      true, event.code, event.signal
    event.clean = event.code == 0 and event.signal == 0
  elseif event.kind == "notification" then
    core.log(
      "%s",
      (event.title and event.title .. ": " or "") .. (event.body or "")
    )
  elseif event.kind == "error" then
    core.error("Ghostty: %s", event.text)
  elseif event.kind == "clipboard-write-request" then
    local policy = view.options.osc52
    if policy == "deny" then
      events.emit("clipboard-write-denied", event)
      return
    end

    ---Apply an accepted OSC 52 write on the editor thread.
    local function accept()
      system.set_clipboard(event.text)
      events.emit("clipboard-write-accepted", event)
    end

    if policy == "allow" then
      accept()
    elseif not view.clipboard_prompt then
      view.clipboard_prompt = true
      core.nag_view:show(
        "Terminal clipboard",
        "Allow this terminal to replace the clipboard?",
        {
          { text = "Allow", default_yes = true },
          { text = "Deny", default_no = true },
        },
        function(item)
          view.clipboard_prompt = false
          if item.text == "Allow" then
            accept()
          else
            events.emit("clipboard-write-denied", event)
          end
        end
      )
    end
  end
  events.emit(event.kind, event)
end

---Drain process events and apply focus/exit policy, including for hidden views.
function TerminalView:poll()
  if not self.terminal then
    return
  end
  for _, event in ipairs(self.terminal:poll_events()) do
    handle_event(self, event)
    if not self.terminal then
      return
    end
  end
  local focused = core.active_view == self
    and system.window_has_focus(core.window)
  if self.focused ~= focused then
    self.terminal:focus(focused)
    self.focused = focused
    if not focused then
      self.pressed, self.pending_key = {}, nil
    end
  end
  local node = core.root_view.root_node:get_node_for_view(self)
  if
    self.terminal:is_dirty()
    and node
    and node.active_view == self
    and self.size.y > 0
  then
    core.redraw = true
  end
  if
    self.exited
    and (
      self.close_on_exit == "always"
      or (
        self.close_on_exit == "clean_exit"
        and self.exit_code == 0
        and self.exit_signal == 0
      )
    )
  then
    close_view(self)
  end
end

-- Poll every session, including hidden tabs, without requiring keyboard events.
core.add_thread(function()
  while true do
    if backend then
      backend.reap()
    end
    for view in pairs(views) do
      local ok = core.try(view.poll, view)
      if not ok then
        view:close()
      end
    end
    -- config.fps includes Auto FPS and changes made in Settings at runtime.
    -- Headless displays can report zero; keep process polling alive there.
    local fps = config.fps > 0 and config.fps or 60
    local interval = config.plugins.ghostty.poll_interval or 1 / fps
    coroutine.yield(math.max(0.001, interval))
  end
end)

local old_exit = core.exit
function core.exit(quit, force)
  return old_exit(function()
    for view in pairs(views) do
      view:close()
    end
    quit()
  end, force)
end

---Return the viewport plus scrollback height in pixels.
---@return number
function TerminalView:get_scrollable_size()
  return self.size.y + self.scrollback_rows * (self.cell_height or 1)
end

---Map Ghostty's row metrics onto Pragtical's scrollbar widget.
function TerminalView:update_scrollbar()
  local state = self.terminal and self.snapshot and self.snapshot.scrollbar
  self.scrollback_rows = state and math.max(0, state.total - state.len) or 0
  self.scrollbar_visible = self.scrollback_rows > 0
    and self.size.x > 0
    and self.size.y > 0
  local bar = self.v_scrollbar
  bar:set_size(
    self.position.x,
    self.position.y,
    self.size.x,
    self.size.y,
    self:get_scrollable_size()
  )
  bar:set_percent(
    self.scrollbar_visible and state.offset / self.scrollback_rows or 0
  )
  -- Small drawers still need room to move the thumb along the track.
  bar.minimum_thumb_size = math.min(style.minimum_thumb_size, self.size.y / 2)
  if not self.scrollbar_visible then
    bar.dragging = false
    bar:on_mouse_left()
  end
  bar:update()
end

---@param x number
---@param y number
---@return boolean
function TerminalView:scrollbar_overlaps_point(x, y)
  return self.scrollbar_visible and self.v_scrollbar:overlaps(x, y) ~= nil
end

---Apply a scrollbar gesture using an absolute row, including between frames.
---@param percent number Position from zero (top) to one (bottom).
function TerminalView:scroll_to_percent(percent)
  if not self.terminal or not self.scrollbar_visible then
    return
  end
  local row = common.round(common.clamp(percent, 0, 1) * self.scrollback_rows)
  self.terminal:scroll_to(row)
  self.v_scrollbar:set_percent(row / self.scrollback_rows)
  self.selection = selection.new()
  core.redraw = true
end

function TerminalView:update()
  TerminalView.super.update(self)
  if not self.terminal or self.size.x <= 0 or self.size.y <= 0 then
    self:update_scrollbar()
    return
  end
  local font = self.options.font or style.code_font
  local cw, ch =
    math.max(1, math.ceil(font:get_width("M"))),
    math.max(1, math.ceil(font:get_height()))
  local cols, rows =
    math.max(2, math.floor(self.size.x / cw)),
    math.max(1, math.floor(self.size.y / ch))
  if
    cols ~= self.cols
    or rows ~= self.rows
    or cw ~= self.cell_width
    or ch ~= self.cell_height
  then
    self.cols, self.rows, self.cell_width, self.cell_height = cols, rows, cw, ch
    self.terminal:resize(cols, rows, cw, ch)
    self.selection = selection.new()
  end
  local fg, bg, cursor =
    self.options.foreground or style.text,
    self.options.background or style.background,
    self.options.cursor or style.caret
  local colors = table.concat(fg, ",")
    .. ";"
    .. table.concat(bg, ",")
    .. ";"
    .. table.concat(cursor, ",")
  if colors ~= self.colors then
    self.terminal:set_colors(fg, bg, cursor)
    self.colors = colors
  end
  local palette_key = palette.signature(style, fg, bg)
  if palette_key ~= self.palette_key then
    self.terminal:set_palette(palette.generate(style, fg, bg))
    self.palette_key = palette_key
  end
  if self.terminal:is_dirty() or not self.snapshot then
    self.snapshot = self.terminal:update_render()
    self.terminal:clear_dirty()
    core.redraw = true
  end
  self:update_scrollbar()
end

---Cache background runs and visible glyphs without changing cell positions.
---@param row table Immutable backend row snapshot.
---@return table
local function drawing_row(row)
  local result = { row = row, backgrounds = {}, glyphs = {} }
  local run
  for _, span in ipairs(row.spans) do
    if run and run.bg == span.bg and run.x + run.width == span.x then
      run.width = run.width + span.width
    else
      run = { x = span.x, width = span.width, bg = span.bg }
      result.backgrounds[#result.backgrounds + 1] = run
    end
    if span.text ~= " " or span.underline or span.strikethrough then
      result.glyphs[#result.glyphs + 1] = span
    end
  end
  return result
end

function TerminalView:draw()
  self:draw_background(
    self.snapshot and self.snapshot.background
      or self.options.background
      or style.background
  )
  if not self.snapshot then
    return
  end
  core.push_clip_rect(
    self.position.x,
    self.position.y,
    self.size.x,
    self.size.y
  )
  local font = self.options.font or style.code_font
  if self.font ~= font or self.font_size ~= font:get_size() then
    self.font, self.font_size = font, font:get_size()
    self.bold_font = font:copy(self.font_size, { bold = true })
    self.italic_font = font:copy(self.font_size, { italic = true })
    self.bold_italic_font =
      font:copy(self.font_size, { bold = true, italic = true })
  end
  local previous_rows = self.drawing_rows or {}
  self.drawing_rows = {}
  for row_index, row in ipairs(self.snapshot.rows_data) do
    local drawing = previous_rows[row_index]
    if not drawing or drawing.row ~= row then
      drawing = drawing_row(row)
    end
    self.drawing_rows[row_index] = drawing
    local y = self.position.y + (row_index - 1) * self.cell_height
    for _, span in ipairs(drawing.backgrounds) do
      if span.bg ~= self.snapshot.background then
        renderer.draw_rect(
          self.position.x + span.x * self.cell_width,
          y,
          span.width * self.cell_width,
          self.cell_height,
          span.bg
        )
      end
    end
    local first, last =
      selection.row_range(self.selection, row_index, self.cols)
    if first then
      renderer.draw_rect(
        self.position.x + (first - 1) * self.cell_width,
        y,
        (last - first + 1) * self.cell_width,
        self.cell_height,
        style.selection
      )
    end
    for _, span in ipairs(drawing.glyphs) do
      local x, width =
        self.position.x + span.x * self.cell_width, span.width * self.cell_width
      local face = span.bold
          and (span.italic and self.bold_italic_font or self.bold_font)
        or (span.italic and self.italic_font or font)
      if span.text ~= " " then
        renderer.draw_text(face, span.text, x, y, span.fg)
      end
      if span.underline then
        renderer.draw_rect(x, y + self.cell_height - 2, width, 1, span.fg)
      end
      if span.strikethrough then
        renderer.draw_rect(
          x,
          y + math.floor(self.cell_height / 2),
          width,
          1,
          span.fg
        )
      end
    end
  end
  local cursor = self.snapshot.cursor
  if cursor.visible then
    local x, y =
      self.position.x + cursor.x * self.cell_width,
      self.position.y + cursor.y * self.cell_height
    local color = cursor.color or self.options.cursor or style.caret
    if cursor.shape == 0 then
      renderer.draw_rect(x, y, 2, self.cell_height, color)
    elseif cursor.shape == 2 then
      renderer.draw_rect(x, y + self.cell_height - 2, self.cell_width, 2, color)
    elseif not self.focused or cursor.shape == 3 then
      renderer.draw_rect(x, y, self.cell_width, 1, color)
      renderer.draw_rect(x, y + self.cell_height - 1, self.cell_width, 1, color)
      renderer.draw_rect(x, y, 1, self.cell_height, color)
      renderer.draw_rect(x + self.cell_width - 1, y, 1, self.cell_height, color)
    else
      local text, width = " ", self.cell_width
      for _, span in ipairs(self.snapshot.rows_data[cursor.y + 1].spans) do
        if span.x == cursor.x then
          text, width = span.text, span.width * self.cell_width
          break
        end
      end
      renderer.draw_rect(x, y, width, self.cell_height, color)
      renderer.draw_text(font, text, x, y, self.snapshot.background)
    end
  end
  if self.scrollbar_visible then
    self.v_scrollbar:draw()
  end
  core.pop_clip_rect()
end

function TerminalView:on_text_input(text)
  if not self.terminal or not text or text == "" then
    return
  end
  self.selection = selection.new()
  local event = self.pending_key
  self.pending_key = nil
  if event then
    event.text = text
    -- SDL has already applied the keyboard layout and Shift to this text.
    -- Keep Shift effective when it did not change the character (e.g. space).
    local unshifted = event.key == "space" and " " or event.key
    event.consumed_mods = { shift = event.mods.shift and text ~= unshifted }
    if self.terminal:send_key(event) then
      self.pressed[event.key] = event
      return
    end
  end
  self.terminal:input_text(text)
end

function TerminalView:on_file_dropped(filename)
  if not self.terminal or filename:find("[%z\1-\31\127]") then
    return false
  end
  self.terminal:input_text(
    shell.quote_path(
      filename,
      type(self.options.shell) == "string" and self.options.shell or nil
    ) .. " "
  )
  return true
end

function TerminalView:copy_selection()
  if not self.terminal or not selection.has_selection(self.selection) then
    return false
  end
  local first, last = selection.range(self.selection)
  local text =
    self.terminal:copy_selection(first.col, first.row, last.col, last.row)
  if not text then
    return false
  end
  system.set_clipboard(text)
  return true
end

function TerminalView:paste()
  if not self.terminal then
    return
  end
  local text = system.get_clipboard()
  if not text or text == "" then
    return
  end
  local ok, reason = self.terminal:paste(text, not self.options.paste_warning)
  if not ok and reason == "unsafe" then
    core.nag_view:show(
      "Terminal paste",
      "This paste contains line breaks or control characters. Paste it?",
      {
        { text = "Paste", default_yes = true },
        { text = "Cancel", default_no = true },
      },
      function(item)
        if item.text == "Paste" and self.terminal then
          self.terminal:paste(text, true)
        end
      end
    )
  end
end

---Convert editor pixels to clamped, one-based terminal cell coordinates.
---@param x number
---@param y number
---@return integer col
---@return integer row
function TerminalView:convert_coordinates(x, y)
  return common.clamp(
    math.floor((x - self.position.x) / (self.cell_width or 1)) + 1,
    1,
    self.cols or 1
  ),
    common.clamp(
      math.floor((y - self.position.y) / (self.cell_height or 1)) + 1,
      1,
      self.rows or 1
    )
end

function TerminalView:send_mouse(action, button, x, y)
  return self.terminal:send_mouse {
    action = action,
    button = button,
    x = x - self.position.x,
    y = y - self.position.y,
    mods = keymap.modkeys,
  }
end

function TerminalView:on_mouse_pressed(button, x, y, clicks)
  if not self.terminal then
    return false
  end
  core.set_active_view(self)
  self.mouse_x, self.mouse_y = x, y
  if self.scrollbar_visible then
    local result = self.v_scrollbar:on_mouse_pressed(button, x, y, clicks)
    if result then
      self.scrollbar_pressed = true
      self.selection = selection.new()
      if result ~= true then
        self:scroll_to_percent(result)
      end
      core.redraw = true
      return true
    end
  end
  local col, row = self:convert_coordinates(x, y)
  if button == "left" and keymap.modkeys[self.options.click_modifier] then
    local uri = self.terminal:hyperlink_at(col, row)
    local detected
    if uri then
      detected =
        { kind = uri:match("^https?://") and "url" or "file_url", target = uri }
    elseif self.snapshot then
      local cells = self.snapshot.rows_data[row].cells
      local byte = 1
      for i = 1, col - 1 do
        byte = byte + #(cells[i] or " ")
      end
      detected = click.detect(table.concat(cells), byte)
    end
    if click.open(detected, self.cwd) then
      events.emit("link-opened", { view = self, target = detected.target })
      return true
    end
  end
  if self.terminal:mouse_tracking() and not keymap.modkeys.shift then
    self.mouse_button = button
    self:send_mouse("press", button, x, y)
    return true
  end
  if button ~= "left" then
    return false
  end
  if clicks == 2 then
    local first, last = self.terminal:word_range(col, row)
    if first then
      selection.start(self.selection, first.col, first.row, last.col, last.row)
      core.redraw = true
      return true
    end
  end
  selection.start(self.selection, col, row)
  core.redraw = true
  return true
end

function TerminalView:on_mouse_moved(x, y, dx, dy)
  self.mouse_x, self.mouse_y = x, y
  if
    self.scrollbar_visible
    and not self.selection.active
    and not self.mouse_button
  then
    local result = self.v_scrollbar:on_mouse_moved(x, y, dx, dy)
    if result then
      if result ~= true then
        self:scroll_to_percent(result)
      end
      return true
    end
  end
  if self.scrollbar_pressed then
    return true
  end
  if self.selection.active then
    local col, row = self:convert_coordinates(x, y)
    if selection.update(self.selection, col, row) then
      core.redraw = true
    end
    return true
  end
  if
    self.terminal
    and self.terminal:mouse_tracking()
    and not keymap.modkeys.shift
  then
    self:send_mouse("motion", self.mouse_button, x, y)
  end
end

function TerminalView:on_mouse_released(button, x, y)
  if self.scrollbar_pressed and button == "left" then
    self.v_scrollbar:on_mouse_released(button, x, y)
    self.scrollbar_pressed = false
    if not self.scrollbar_visible then
      self.v_scrollbar:on_mouse_left()
    end
    core.redraw = true
    return true
  end
  if self.selection.active then
    if button == "left" then
      selection.finish(self.selection)
      core.redraw = true
    end
    return true
  end
  if self.terminal and self.terminal:mouse_tracking() then
    self:send_mouse("release", button, x, y)
  end
  self.mouse_button = nil
end

function TerminalView:on_mouse_left()
  self.v_scrollbar:on_mouse_left()
end

function TerminalView:on_mouse_wheel(delta)
  if not self.terminal or delta == 0 then
    return false
  end
  self.selection = selection.new()
  local over_scrollbar = self:scrollbar_overlaps_point(
    self.mouse_x or self.position.x,
    self.mouse_y or self.position.y
  )
  if
    self.terminal:mouse_tracking()
    and not keymap.modkeys.shift
    and not over_scrollbar
  then
    for _ = 1, common.clamp(math.floor(math.abs(delta)), 1, 10) do
      self:send_mouse(
        "press",
        delta > 0 and "wheel_up" or "wheel_down",
        self.mouse_x or self.position.x,
        self.mouse_y or self.position.y
      )
    end
  else
    self.terminal:scroll(delta > 0 and -3 or 3)
  end
  return true
end

---Open and focus a new terminal tab in the active editor pane.
---@param options? plugins.ghostty.options
---@return plugins.ghostty.TerminalView
local function open_tab(options)
  local view = TerminalView(options)
  core.root_view:get_active_node_default():add_view(view)
  return view
end

---Open or focus the bottom drawer. Options apply only when creating it.
---@param options? plugins.ghostty.options
---@return plugins.ghostty.TerminalView
local function open_drawer(options)
  if not drawer then
    previous_view = core.active_view
    drawer = TerminalView(options)
    drawer.size.y = drawer.options.drawer_height
    drawer_node = core.root_view
      :get_active_node_default()
      :split("down", drawer, { y = true }, true)
  elseif drawer_hidden then
    drawer_node:resize("y", drawer_hidden)
    drawer_hidden = nil
  end
  core.set_active_view(drawer)
  return drawer
end

---Hide or restore the drawer without stopping its process.
---@return plugins.ghostty.TerminalView
local function toggle_drawer()
  if not drawer or drawer_hidden then
    return open_drawer()
  end
  drawer_hidden = math.max(1, drawer.size.y)
  drawer_node:resize("y", 0)
  if
    previous_view and core.root_view.root_node:get_node_for_view(previous_view)
  then
    core.set_active_view(previous_view)
  else
    for _, view in ipairs(core.root_view.root_node:get_children()) do
      if view ~= drawer then
        core.set_active_view(view)
        break
      end
    end
  end
  return drawer
end

command.add(nil, {
  ["ghostty:open-tab"] = open_tab,
  ["ghostty:open-drawer"] = open_drawer,
  ["ghostty:toggle-drawer"] = toggle_drawer,

  ["ghostty:spawn-agent"] = function(text)

    ---@param value string Shell command entered by the user.
    local function spawn(value)
      open_tab { kind = "agent", title = value, command = value, shell = true }
    end

    if text then
      return spawn(text)
    end
    core.command_view:enter("Terminal Command", { submit = spawn })
  end,
})
command.add(TerminalView, {
  ["ghostty:close-terminal"] = close_view,

  ---@param view plugins.ghostty.TerminalView
  ["ghostty:copy-selection"] = function(view)
    view:copy_selection()
  end,

  ---@param view plugins.ghostty.TerminalView
  ["ghostty:paste"] = function(view)
    view:paste()
  end,

  ---@param view plugins.ghostty.TerminalView
  ["ghostty:clear"] = function(view)
    if view.terminal then
      view.terminal:input_text("\12")
    end
  end,

  ---@param view plugins.ghostty.TerminalView
  ["ghostty:reset"] = function(view)
    if view.terminal then
      view.terminal:reset()
      view.selection = selection.new()
      view.pressed, view.pending_key, view.mouse_button = {}, nil, nil
      view:update()
    end
  end,

  ---@param view plugins.ghostty.TerminalView
  ["ghostty:scroll-up"] = function(view)
    if view.terminal then
      view.terminal:scroll(-3)
    end
  end,

  ---@param view plugins.ghostty.TerminalView
  ["ghostty:scroll-down"] = function(view)
    if view.terminal then
      view.terminal:scroll(3)
    end
  end,
})
keymap.add {
  ["alt+t"] = "ghostty:toggle-drawer",
  ["shift+alt+t"] = "ghostty:open-drawer",
  ["ctrl+shift+`"] = "ghostty:open-tab",
  ["ctrl+shift+c"] = "ghostty:copy-selection",
  ["ctrl+shift+v"] = "ghostty:paste",
  ["ctrl+shift+w"] = "ghostty:close-terminal",
}
if PLATFORM == "Mac OS X" then
  keymap.add {
    ["cmd+c"] = "ghostty:copy-selection",
    ["cmd+v"] = "ghostty:paste",
  }
end

local modifier_def =
  require("core.modkeys-" .. (PLATFORM == "Mac OS X" and "macos" or "generic"))
local modifier_map = modifier_def.map
local old_pressed, old_released = keymap.on_key_pressed, keymap.on_key_released
local editor_keys =
  { ["ctrl+shift+p"] = true, ["ctrl+tab"] = true, ["ctrl+shift+tab"] = true }

---@param key string Pragtical key name without modifiers.
---@return boolean
local function editor_binding(key)
  local parts = {}
  for _, name in ipairs(modifier_def.keys) do
    if keymap.modkeys[name] then
      parts[#parts + 1] = name
    end
  end
  parts[#parts + 1] = key
  local stroke = table.concat(parts, "+")
  if editor_keys[stroke] then
    return true
  end
  for _, action in ipairs(keymap.map[stroke] or {}) do
    if type(action) == "string" and action:match("^ghostty:") then
      return true
    end
  end
  return false
end

function keymap.on_key_pressed(key, ...)
  local view = core.active_view
  if
    not views[view]
    or not view.terminal
    or modifier_map[key]
    or editor_binding(key)
  then
    return old_pressed(key, ...)
  end
  local mods = common.merge({}, keymap.modkeys)
  local event = { key = key, mods = mods, repeated = view.pressed[key] ~= nil }
  local printable = #key == 1 or key == "space"
  if printable and not (mods.ctrl or mods.alt or mods.cmd) then
    -- SDL textinput supplies layout-aware text and repeats, including IME.
    view.pending_key = event
    return false
  end
  if printable then
    event.text = key == "space" and " " or (mods.shift and key:upper() or key)
  end
  view.pending_key = nil
  if view.terminal:send_key(event) then
    view.pressed[key] = event
  end
  return true
end

function keymap.on_key_released(key, ...)
  local view = core.active_view
  if views[view] and view.terminal and view.pressed[key] then
    local event = view.pressed[key]
    event.released = true
    view.terminal:send_key(event)
    view.pressed[key] = nil
  end
  return old_released(key, ...)
end

return {
  TerminalView = TerminalView,

  ---@param options? plugins.ghostty.options
  ---@return plugins.ghostty.TerminalView
  new_terminal = function(options)
    return TerminalView(options)
  end,

  open_tab = open_tab,
  open_drawer = open_drawer,
  on = events.on,
  off = events.off,
  emit = events.emit,
}
