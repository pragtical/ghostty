-- Runs with `luajit tests/backend.lua` and Pragtical's test runner.
local ffi = require "ffi"
local windows = ffi.os == "Windows"
local in_editor, test = pcall(require, "core.test")
if not in_editor then

  package.preload["plugins.ghostty.config"] = function()
    return {
      max_scrollback = 1000,
      osc_max_bytes = 4096,
      read_budget = 262144,
      write_limit = 4194304,
      shell = windows and (os.getenv("COMSPEC") or "cmd.exe") or "/bin/sh",
      term = "xterm-256color",
      runtime_path = os.getenv("GHOSTTY_RUNTIME"),
      pty_path = os.getenv("GHOSTTY_PTY_RUNTIME"),
    }
  end
end
local source = debug.getinfo(1, "S").source:sub(2)
local root = source:match("^(.*)[/\\]tests[/\\]") or "."
if not in_editor then
  local data = os.getenv("PRAGTICAL_DATA_DIR") or root .. "/../pragtical/data"
  package.path = data .. "/?.lua;" .. package.path
end
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
local backend = require "plugins.ghostty.terminal"
local pty = require "plugins.ghostty.pty"
local runtime = require "plugins.ghostty.runtime"
local palette = require "plugins.ghostty.palette"
local json = require "core.json"
ffi.cdef [[
  int usleep(unsigned int);
  int kill(int, int);
  void __stdcall Sleep(unsigned long);
]]

---Yield briefly while allowing asynchronous PTY cleanup to make progress.
local function pause()
  pty.C.pgt_pty_reap()
  if in_editor then
    coroutine.yield(0.005)
  elseif windows then
    ffi.C.Sleep(5)
  else
    ffi.C.usleep(5000)
  end
end

local count = 0

---@param name string
---@param fn fun()
local function it(name, fn)
  if in_editor then
    test.it(name, fn)
  else
    fn()
    count = count + 1
    print("ok " .. count .. " - " .. name)
  end
end

---@param actual any
---@param expected any
local function equal(actual, expected)
  assert(
    actual == expected,
    string.format("expected %q, got %q", tostring(expected), tostring(actual))
  )
end

---@param t plugins.ghostty.Terminal
---@return string text
---@return table snapshot
local function screen(t)
  local snapshot = t:update_render()
  local rows = {}
  for _, row in ipairs(snapshot.rows_data) do
    rows[#rows + 1] = table.concat(row.cells):gsub("%s+$", "")
  end
  return table.concat(rows, "\n"), snapshot
end

---@param t plugins.ghostty.Terminal
---@return string Queued input, removed from the terminal after reading.
local function sent(t)
  local result = table.concat(t.writes, "", t.write_head, t.write_tail)
  t.writes, t.write_head, t.write_tail, t.write_offset, t.pending_bytes =
    {}, 1, 0, 0, 0
  return result
end

---@param options? plugins.ghostty.options
---@param fn fun(terminal: plugins.ghostty.Terminal)
local function with_terminal(options, fn)
  local t = backend.new(options or { command = false, cols = 20, rows = 4 })
  local ok, err = pcall(fn, t)
  t:close()
  if not ok then
    error(err, 0)
  end
end

it("FFI struct layouts agree with the C headers", function()
  local probe = os.getenv("GHOSTTY_ABI_PROBE")
  if not probe then
    return
  end
  local file = assert(
    io.popen(
      windows and ('"' .. probe .. '"')
        or ("'" .. probe:gsub("'", "'\\''") .. "'")
    )
  )
  for line in file:lines() do
    local name, n = line:match("^(%S+) (%d+)$")
    local struct, field = name:match("^(.-)%.(.*)$")
    equal(
      struct and ffi.offsetof(struct, field) or ffi.sizeof(name),
      tonumber(n)
    )
  end
  assert(file:close())
end)

it("rejects incompatible ABI schemas, layouts and field offsets", function()
  local metadata = ffi.string(runtime.C.ghostty_type_json())
  assert(runtime.verify_abi(metadata) >= 10)

  ---@param value string ABI metadata to reject.
  ---@param message string Expected error substring.
  local function rejected(value, message)
    local ok, err = pcall(runtime.verify_abi, value)
    assert(not ok and tostring(err):find(message, 1, true), tostring(err))
  end

  rejected(
    metadata:gsub('"schema":1', '"schema":2', 1),
    "Unsupported libghostty ABI schema"
  )
  rejected(
    metadata:gsub('"schema":1,', "", 1),
    "Unsupported libghostty ABI schema"
  )
  rejected(
    metadata:gsub('("GhosttyPoint":%{"kind":"struct","size":)%d+', "%1999", 1),
    "Incompatible libghostty layout: GhosttyPoint"
  )
  rejected(
    metadata:gsub('("GhosttyPoint":)(%b{})', function(name, descriptor)
      return name .. descriptor:gsub('("value":%{"offset":)%d+', "%1999", 1)
    end, 1),
    "Incompatible libghostty field: GhosttyPoint.value"
  )
  rejected('{"schema":1,"types":{}}', "Cannot verify libghostty ABI")
  rejected('{"schema":1,"types":null}', "Missing libghostty ABI types")
  rejected(metadata .. " trailing garbage", "Invalid libghostty ABI metadata")
end)

it(
  "reads ABI metadata independently of JSON formatting and field order",
  function()
    local metadata = ffi.string(runtime.C.ghostty_type_json())
    local point = json.decode(metadata).types.GhosttyPoint

    local reordered = metadata:gsub('("GhosttyPoint":)(%b{})', function(name)
      return name
        .. '{"fields":'
        .. json.encode(point.fields)
        .. ',"align":'
        .. point.align
        .. ',"kind":"struct","size":'
        .. point.size
        .. "}"
    end, 1)
    equal(
      runtime.verify_abi(json.prettify(reordered)),
      runtime.verify_abi(metadata)
    )
  end
)

it(
  "applies the configured scrollback limit through the terminal options API",
  function()
    for _, limit in ipairs { 0, 23, 10000 } do

      with_terminal({ command = false, max_scrollback = limit }, function(t)
        local value = ffi.new("size_t[1]")
        runtime.check(
          runtime.C.ghostty_terminal_get(
            t.terminal,
            runtime.C.GHOSTTY_TERMINAL_DATA_SCROLLBACK_MAX_LINES,
            value
          )
        )
        equal(tonumber(value[0]), limit)
      end)
    end
  end
)

it(
  "generates readable ANSI colors from dark, light and monochrome themes",
  function()

    ---@param rgb integer[]
    ---@return number
    local function luminance(rgb)
      local total = 0
      for i, weight in ipairs { 0.2126, 0.7152, 0.0722 } do
        local c = rgb[i] / 255
        total = total
          + weight
            * (c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4)
      end
      return total
    end

    ---@param a integer[]
    ---@param b integer[]
    ---@return number
    local function contrast(a, b)
      local x, y = luminance(a), luminance(b)
      return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05)
    end

    local theme = {
      syntax = {
        string = { 230, 95, 100 },
        number = { 110, 210, 95 },
        literal = { 235, 200, 100 },
        keyword = { 105, 160, 240 },
        operator = { 205, 125, 215 },
        ["function"] = { 90, 200, 200 },
      },
    }
    local fg, bg = { 225, 225, 225 }, { 20, 20, 20 }
    local colors = palette.generate(theme, fg, bg)
    -- Match hues rather than assuming, for example, that strings are green.
    for channel = 1, 3 do
      equal(colors[2][channel], theme.syntax.string[channel])
      equal(colors[3][channel], theme.syntax.number[channel])
      equal(colors[5][channel], theme.syntax.keyword[channel])
    end
    local sparse =
      { syntax = { number = { 71, 196, 241 } }, caret = { 135, 170, 222 } }
    local generated = palette.generate(sparse, fg, bg)
    for channel = 1, 3 do
      -- Blue stays distinct from cyan.
      equal(generated[5][channel], sparse.caret[channel])
      equal(generated[7][channel], sparse.syntax.number[channel])
    end
    local key = palette.signature(theme, fg, bg)
    theme.syntax.string[2] = 120
    assert(
      key ~= palette.signature(theme, fg, bg),
      "In-place theme edits must invalidate the palette"
    )
    for _, background in ipairs { bg, { 245, 240, 230 }, { 118, 118, 118 } } do
      for _, source in ipairs {
        theme,
        {},
        { syntax = { keyword = { 128, 128, 128 } } },
      } do
        local generated = palette.generate(source, fg, background)
        equal(#generated, 16)
        local distinct = {}
        for i, rgb in ipairs(generated) do
          for channel = 1, 3 do
            assert(
              rgb[channel] >= 0
                and rgb[channel] <= 255
                and rgb[channel] % 1 == 0
            )
          end
          if i ~= 1 and i ~= 9 then
            assert(contrast(rgb, background) >= 4.5)
          end
          if i >= 2 and i <= 7 then
            assert(
              not distinct[table.concat(rgb, ",")],
              "ANSI accents must remain distinct"
            )
            distinct[table.concat(rgb, ",")] = true
            assert(
              contrast(generated[i + 8], background)
                >= contrast(rgb, background)
            )
          end
        end
        assert(contrast(generated[9], background) >= 3)
      end
    end
    equal(theme.syntax.keyword[1], 105) -- Generation must not edit the theme.
  end
)

it(
  "updates ANSI colors while preserving extended colors and OSC overrides",
  function()
    local colors = palette.generate({}, { 225, 225, 225 }, { 20, 20, 20 })
    with_terminal(
      { command = false, cols = 40, rows = 3, palette = colors },
      function(t)
        local original = ffi.new("GhosttyColorRgb[256]")
        runtime.check(
          runtime.C.ghostty_terminal_get(
            t.terminal,
            runtime.C.GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT,
            original
          )
        )
        for i = 0, 15 do
          t:feed(string.format("\27[%dmX", i < 8 and 30 + i or 90 + i - 8))
        end
        t:feed("\r\n")
        for i = 0, 15 do
          t:feed(string.format("\27[38;5;%dmX", i))
        end
        t:feed("\27[38;5;196mR\27[38;5;244mG\27[38;2;12;34;56mT")
        local _, snapshot = screen(t)
        for row = 1, 2 do
          for i = 1, 16 do
            for channel = 1, 3 do
              equal(
                snapshot.rows_data[row].spans[i].fg[channel],
                colors[i][channel]
              )
            end
          end
        end
        local extended = snapshot.rows_data[2].spans
        equal(extended[17].fg[1], 255)
        equal(extended[17].fg[2], 0)
        equal(extended[18].fg[1], 128)
        equal(extended[19].fg[2], 34)
        -- Palette changes must repaint existing cells without new output.
        local replacement = palette.generate(
          {},
          { 30, 30, 30 },
          { 250, 250, 250 }
        )
        t:feed("\27]4;1;rgb:12/34/56\7")
        t:set_palette(replacement)
        _, snapshot = screen(t)
        equal(snapshot.rows_data[1].spans[2].fg[1], 0x12)
        equal(snapshot.rows_data[1].spans[3].fg[2], replacement[3][2])
        t:feed("\27]104;1\7")
        _, snapshot = screen(t)
        equal(snapshot.rows_data[1].spans[2].fg[1], replacement[2][1])
        equal(snapshot.rows_data[2].spans[19].fg[2], 34)
        local updated = ffi.new("GhosttyColorRgb[256]")
        runtime.check(
          runtime.C.ghostty_terminal_get(
            t.terminal,
            runtime.C.GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT,
            updated
          )
        )
        for i = 16, 255 do
          equal(updated[i].r, original[i].r)
          equal(updated[i].g, original[i].g)
          equal(updated[i].b, original[i].b)
        end
      end
    )
  end
)

it(
  "renders UTF-8, combining characters, wide cells and blank backgrounds",
  function()
    with_terminal(nil, function(t)
      t:feed("Aé界é\27[41m  \27[0m")
      local _, s = screen(t)
      equal(s.rows_data[1].cells[1], "A")
      equal(s.rows_data[1].cells[2], "é")
      equal(s.rows_data[1].cells[3], "界")
      equal(s.rows_data[1].cells[4], "")
      equal(s.rows_data[1].cells[5], "é")
      equal(s.rows_data[1].spans[3].width, 2)
      assert(s.rows_data[1].spans[5].bg[1] > 100)
      equal(t:copy_selection(2, 1, 5, 1), "é界é")
      equal(s.cursor.x, 7)
    end)
  end
)

it(
  "renders long grapheme clusters and emoji through the UTF-8 buffer API",
  function()
    with_terminal(nil, function(t)
      local cluster = "e" .. string.rep("́", 40)
      t:feed(cluster .. "😀Z")
      local cells = t:update_render().rows_data[1].cells
      equal(cells[1], cluster)
      equal(cells[2], "😀")
      equal(cells[3], "")
      equal(cells[4], "Z")
      equal(cells[5], " ")
    end)
  end
)

it(
  "reuses unchanged cells without mutating earlier render snapshots",
  function()
    with_terminal(nil, function(t)
      t:feed("\27[31mAB界\27[0m\r\nunchanged")
      local first = t:update_render()
      t:feed("\27[H\27[31mAB界\27[0m")
      local same = t:update_render()
      equal(same.rows_data[1], first.rows_data[1])
      t:feed("\27[2G\27[31mZ\27[0m")
      local changed = t:update_render()
      equal(first.rows_data[1].cells[2], "B")
      equal(changed.rows_data[1].cells[2], "Z")
      equal(changed.rows_data[1].spans[1], first.rows_data[1].spans[1])
      equal(changed.rows_data[2], first.rows_data[2])
      t:feed("\27[2G\27[32;1;3;4;9mZ\27[0m")
      local styled = t:update_render().rows_data[1].spans[2]
      assert(styled.bold and styled.italic and styled.underline)
      assert(styled.strikethrough)
      assert(styled.fg ~= changed.rows_data[1].spans[2].fg)
      assert(not changed.rows_data[1].spans[2].bold)
      t:feed("\27[3G\27[K")
      local erased = t:update_render().rows_data[1]
      equal(erased.cells[3], " ")
      equal(erased.cells[4], " ")
      equal(erased.spans[3].width, 1)
      equal(first.rows_data[1].cells[3], "界")
      t:resize(5, 3, 9, 18)
      local resized = t:update_render()
      equal(#resized.rows_data, 3)
      equal(#resized.rows_data[1].cells, 5)
    end)
  end
)

it(
  "applies truecolor, inverse, hidden text, underline and cursor shape",
  function()
    with_terminal(nil, function(t)
      t:feed(
        "\27[38;2;10;20;30m\27[48;2;40;50;60m\27[1;3;4;7mX\27[0;8mY\27[5 q"
      )
      local _, s = screen(t)
      local span = s.rows_data[1].spans[1]
      equal(span.fg[1], 40)
      equal(span.bg[1], 10)
      assert(span.bold and span.italic and span.underline)
      span = s.rows_data[1].spans[2]
      equal(span.fg[1], span.bg[1])
      equal(s.cursor.shape, 0)
    end)
  end
)

it("preserves alternate-screen contents and scrollback", function()
  with_terminal(nil, function(t)
    t:feed("primary\27[?1049h\27[2J\27[Halternate")
    assert(screen(t):find("alternate", 1, true))
    t:feed("\27[?1049l")
    assert(screen(t):find("primary", 1, true))
    for i = 1, 20 do
      t:feed("\r\nline" .. i)
    end
    t:scroll(-10)
    assert(not screen(t):find("line20", 1, true))
    t:scroll_bottom()
    assert(screen(t):find("line20", 1, true))
    t:resize(10, 5, 9, 18)
    local _, s = screen(t)
    equal(s.cols, 10)
    equal(s.rows, 5)
  end)
end)

it("scrolls to absolute rows using Ghostty's scrollbar metrics", function()
  with_terminal(nil, function(t)
    local lines = {}
    for i = 1, 40 do
      lines[i] = string.format("line%02d", i)
    end
    t:feed(table.concat(lines, "\r\n"))
    local state = t:update_render().scrollbar
    equal(state.total, 40)
    equal(state.len, 4)
    equal(state.offset, 36)
    t:scroll_to(0)
    equal(t:update_render().scrollbar.offset, 0)
    assert(screen(t):find("line01", 1, true))
    t:scroll_to(10)
    t:scroll_to(20) -- Several mouse events may arrive before a render.
    equal(t:update_render().scrollbar.offset, 20)
    assert(screen(t):find("line21", 1, true))
    t:scroll_to(-10)
    equal(t:update_render().scrollbar.offset, 0)
    t:scroll_to(1000)
    equal(t:update_render().scrollbar.offset, 36)
    t:resize(20, 8, 9, 18)
    state = t:update_render().scrollbar
    equal(state.len, 8)
    equal(state.offset, state.total - state.len)
    t:feed("\27[?1049h")
    t:scroll_to(1000)
    state = t:update_render().scrollbar
    equal(state.total, state.len)
    equal(state.offset, 0)
    t:feed("\27[?1049l")
    t:scroll_to(10)
    equal(t:update_render().scrollbar.offset, 10)
  end)
end)

it(
  "answers device and cursor queries through retained callbacks under JIT load",
  function()
    with_terminal(nil, function(t)
      for _ = 1, 300 do
        t:feed("\27[6n")
      end
      assert(sent(t):find("\27[1;1R", 1, true))
      t:feed("\27[c\27[18t")
      local reply = sent(t)
      assert(reply:find("\27[?62;", 1, true))
      assert(reply:find("\27[8;4;20t", 1, true))
    end)
  end
)

it(
  "encodes application cursor keys, modifiers, Kitty keys and key releases",
  function()
    with_terminal(nil, function(t)
      assert(t:send_key { key = "up" })
      equal(sent(t), "\27[A")
      t:feed("\27[?1h")
      assert(t:send_key { key = "up" })
      equal(sent(t), "\27OA")
      assert(t:send_key { key = "c", text = "c", mods = { ctrl = true } })
      equal(sent(t), "\3")
      assert(t:send_key { key = "tab", mods = { shift = true } })
      equal(sent(t), "\27[Z")
      t:feed("\27[>3u")
      assert(t:send_key { key = "a", text = "a", mods = { ctrl = true } })
      assert(sent(t):find("97;5u", 1, true))
      t:send_key { key = "a", released = true, mods = { ctrl = true } }
      assert(sent(t):find("97;5:3u", 1, true))
    end)
  end
)

it("distinguishes Shift consumed by text from keyboard modifiers", function()
  with_terminal(nil, function(t)
    for _, flags in ipairs { 0, 1, 3, 5, 7 } do
      t:feed("\27[=" .. flags .. "u")
      for _, pair in ipairs {
        { ";", ":" },
        { "'", '"' },
        { "1", "!" },
        { "/", "?" },
        { "[", "{" },
        { "a", "A" },
      } do
        assert(t:send_key {
          key = pair[1],
          text = pair[2],
          mods = { shift = true },
          consumed_mods = { shift = true },
        })
        equal(sent(t), pair[2])
      end
    end
    t:feed("\27[=1u")
    assert(t:send_key {
      key = "a",
      text = "A",
      mods = { ctrl = true, shift = true },
      consumed_mods = { shift = true },
    })
    equal(sent(t), "\27[97;6u")
    assert(t:send_key { key = "tab", mods = { shift = true } })
    equal(sent(t), "\27[9;2u")
    assert(t:send_key { key = " ", text = " ", mods = { shift = true } })
    equal(sent(t), "\27[32;2u")
    -- Applications requesting all keys still receive shifted key identities,
    -- associated text, and release events through Ghostty's encoder.
    t:feed("\27[=31u")
    local event = {
      key = ";",
      text = ":",
      mods = { shift = true },
      consumed_mods = { shift = true },
    }
    assert(t:send_key(event))
    equal(sent(t), "\27[59:58;2;58u")
    event.released = true
    assert(t:send_key(event))
    equal(sent(t), "\27[59:58;2:3u")
  end)
end)

it(
  "encodes named Space presses, repeats and releases with the correct identity",
  function()
    with_terminal(nil, function(t)
      local cases = {
        { flags = 0, press = " ", repeat_key = " ", release = "" },
        { flags = 1, press = " ", repeat_key = " ", release = "" },
        { flags = 3, press = " ", repeat_key = " ", release = "\27[32;1:3u" },
        { flags = 7, press = " ", repeat_key = " ", release = "\27[32;1:3u" },
        {
          flags = 15,
          press = "\27[32u",
          repeat_key = "\27[32;1:2u",
          release = "\27[32;1:3u",
        },
        {
          flags = 31,
          press = "\27[32;;32u",
          repeat_key = "\27[32;1:2;32u",
          release = "\27[32;1:3u",
        },
        {
          flags = 0,
          mods = { ctrl = true },
          press = "\0",
          repeat_key = "\0",
          release = "",
        },
        {
          flags = 3,
          mods = { shift = true },
          press = "\27[32;2u",
          repeat_key = "\27[32;2:2u",
          release = "\27[32;2:3u",
        },
        {
          flags = 3,
          mods = { ctrl = true },
          press = "\27[32;5u",
          repeat_key = "\27[32;5:2u",
          release = "\27[32;5:3u",
        },
      }
      for _, case in ipairs(cases) do
        t:feed("\27[=" .. case.flags .. "u")
        for _, key in ipairs { "space", " " } do
          local event = { key = key, text = " ", mods = case.mods }
          assert(t:send_key(event))
          equal(sent(t), case.press)
          event.repeated = true
          assert(t:send_key(event))
          equal(sent(t), case.repeat_key)
          event.released = true
          assert(t:send_key(event))
          equal(sent(t), case.release)
        end
      end
    end)
  end
)

it(
  "encodes bracketed paste and refuses unsafe paste until confirmed",
  function()
    with_terminal(nil, function(t)
      local ok, why = t:paste("a\nb")
      assert(not ok and why == "unsafe")
      equal(sent(t), "")
      t:feed("\27[?2004h")
      assert(t:paste("a\nb", true))
      equal(sent(t), "\27[200~a\nb\27[201~")
    end)
  end
)

it("reports focus only when requested and encodes SGR mouse input", function()
  with_terminal(nil, function(t)
    t:focus(true)
    equal(sent(t), "")
    t:feed("\27[?1004h\27[?1000h\27[?1006h")
    assert(t:mouse_tracking())
    t:focus(true)
    t:focus(false)
    equal(sent(t), "\27[I\27[O")
    assert(t:send_mouse { action = "press", button = "left", x = 16, y = 16 })
    equal(sent(t), "\27[<0;3;2M")
    assert(t:send_mouse { action = "release", button = "left", x = 16, y = 16 })
    equal(sent(t), "\27[<0;3;2m")
    for _, mode in ipairs { 1002, 1003 } do
      t:feed("\27[?" .. mode .. "h")
      assert(t:send_mouse { action = "press", button = "left", x = 16, y = 16 })
      equal(sent(t), "\27[<0;3;2M")
      assert(t:send_mouse {
        action = "motion",
        button = "left",
        x = -8,
        y = -8,
      })
      equal(sent(t), "\27[<32;1;1M")
      assert(t:send_mouse {
        action = "release",
        button = "left",
        x = -8,
        y = -8,
      })
      equal(sent(t), "\27[<0;1;1m")
      assert(not t:send_mouse { action = "motion", x = -8, y = -8 })
      assert(not t:send_mouse {
        action = "press",
        button = "wheel_up",
        x = -8,
        y = -8,
      })
      equal(sent(t), "")
    end
  end)
end)

it("resets stale modes without changing Ctrl+\\ input", function()
  with_terminal(nil, function(t)
    t:feed("history\r\n\27[?1049h\27[?1003h\27[?1006h")
    t:feed("\27[?1004h\27[?2004h\27[?25lbroken")
    t:update_render()
    assert(t:mouse_tracking())
    t:send_key { key = "\\", text = "\\", mods = { ctrl = true } }
    equal(sent(t), "\28")
    assert(t:mouse_tracking())
    t:feed("\27[>31u")
    t:send_mouse { action = "motion", x = 16, y = 16 }
    equal(sent(t), "\27[<35;3;2M")
    t:reset()
    assert(t:is_dirty())
    assert(not t:mouse_tracking())
    assert(not t:mode(1049))
    assert(not t:bracketed_paste())
    local output, snapshot = screen(t)
    equal(output:gsub("%s", ""), "")
    equal(snapshot.scrollbar.total, snapshot.scrollbar.len)
    assert(snapshot.cursor.visible)
    t:send_mouse { action = "press", button = "left", x = 16, y = 16 }
    t:focus(true)
    equal(sent(t), "")
    t:send_key { key = "a", text = "a" }
    equal(sent(t), "a")
    t:feed("\27[?1003h\27[?1006h")
    t:send_mouse { action = "motion", x = 16, y = 16 }
    equal(sent(t), "\27[<35;3;2M")
    t:close()
    t:reset()
  end)
end)

it("cancels incomplete control strings when resetting", function()
  with_terminal(nil, function(t)
    for _, prefix in ipairs { "\27[?", "\27]52;c;", "\27P", "\27_" } do
      t:feed("\27[?1003h" .. prefix)
      t:reset()
      t:feed("ready\27]52;c;b2s=\7")
      assert(screen(t):find("ready", 1, true))
      assert(not t:mouse_tracking())
      local events = t:poll_events()
      equal(#events, 1)
      equal(events[1].kind, "clipboard-write-request")
      equal(events[1].text, "ok")
    end
  end)
end)

it(
  "extracts links and emits title, cwd and clipboard events across chunks",
  function()
    with_terminal(nil, function(t)
      t:feed("\27]8;;https://example.com\27\\link\27]8;;\27\\")
      equal(t:hyperlink_at(1, 1), "https://example.com")
      local data =
        "\27]2;Title\7\27]7;file://localhost/tmp\27\\\27]52;c;aGVsbG8=\27\\"
      for i = 1, #data do
        t:feed(data:sub(i, i))
      end
      local found = {}
      for _, event in ipairs(t:poll_events()) do
        found[event.kind] = event
      end
      equal(found["title-changed"].title, "Title")
      assert(found["cwd-changed"].cwd:find("/tmp", 1, true))
      equal(found["clipboard-write-request"].text, "hello")
    end)
  end
)

it(
  "bounds OSC messages and ignores clipboard queries and embedded controls",
  function()
    local Osc = require "plugins.ghostty.osc"
    local events = {}

    local osc = Osc.new(32, function(event)
      events[#events + 1] = event
    end)

    osc:feed("\27]52;c;?\7\27]52;c;" .. string.rep("A", 100) .. "\7")
    osc:feed("\27P\27]52;c;aGVsbG8=\7\27\\")
    equal(#events, 0)
    osc:feed("\27]52;c;aGVsbG8=\7")
    equal(#events, 1)
    equal(events[1].text, "hello")
  end
)

it("selects wrapped words within the viewport using Ghostty", function()
  with_terminal({ command = false, cols = 24, rows = 4 }, function(t)
    t:feed("foo_bar/baz  é界 z\r\nlast")
    for _, col in ipairs { 2, 4, 8 } do
      local first, last = t:word_range(col, 1)
      equal(first.col, 1)
      equal(last.col, 11)
      equal(t:copy_selection(first.col, first.row, last.col, last.row),
        "foo_bar/baz")
    end
    local first, last = t:word_range(16, 1) -- Wide-character spacer.
    equal(first.col, 14)
    equal(last.col, 16)
    equal(t:copy_selection(first.col, first.row, last.col, last.row), "é界")
    first, last = t:word_range(18, 1)
    equal(first.col, 18)
    equal(last.col, 18)
    equal(t:word_range(24, 4), nil) -- Unwritten cells have no word.
    t:close()
    equal(t:word_range(1, 1), nil)
  end)
  with_terminal({ command = false, cols = 4, rows = 2 }, function(t)
    t:feed("abcdefghijkl")
    local first, last = t:word_range(2, 1)
    equal(first.col, 1)
    equal(first.row, 1)
    equal(last.col, 4)
    equal(last.row, 2)
    equal(t:copy_selection(first.col, first.row, last.col, last.row),
      "efghijkl") -- The beginning of the word is above the viewport.
    t:scroll_to(0)
    first, last = t:word_range(2, 1)
    equal(first.col, 1)
    equal(first.row, 1)
    equal(last.col, 4)
    equal(last.row, 2)
    equal(t:copy_selection(first.col, first.row, last.col, last.row),
      "abcdefgh") -- The end of the word is below the viewport.
  end)
end)

it("reuses callbacks and releases terminal resources repeatedly", function()
  for _ = 1, 150 do
    local t = backend.new { command = false }
    t:feed("\7\27[6n")
    t:poll_events()
    t:close()
    t:close()
  end
  collectgarbage("collect")
end)

-- QEMU checks VT instructions; process/TTY behavior is covered natively.
if not in_editor and os.getenv("GHOSTTY_TEST_VT_ONLY") == "1" then
  print(count .. " VT backend tests passed")
  return
end

it(
  "spawns a real PTY, drains final output and preserves failure exit codes",
  function()
    local argv = windows
        and { "cmd.exe", "/d", "/s", "/c", "echo pty:%PGT_TEST% & exit /b 7" }
      or {
        "/bin/sh",
        "-c",
        "test -t 0 && test -t 1 && printf 'pty:%s:' \"$PGT_TEST\" "
          .. "&& pwd; exit 7",
      }
    with_terminal({
      command = argv,
      cwd = windows and os.getenv("TEMP") or "/tmp",
      env = { PGT_TEST = "yes" },
      cols = 80,
      rows = 4,
    }, function(t)
      local exited
      for _ = 1, 600 do
        for _, event in ipairs(t:poll_events()) do
          if event.kind == "terminal-exited" then
            exited = event
          end
        end
        if exited then
          break
        end
        pause()
      end
      assert(exited, "child did not exit")
      equal(exited.code, 7)
      local output = screen(t)
      assert(
        output:find(windows and "pty:yes" or "pty:yes:/tmp", 1, true)
          or output:find("pty:yes:/private/tmp", 1, true)
      )
    end)
  end
)
if not windows then
  it("queues partial PTY writes without losing a large paste", function()
    with_terminal({
      command = {
        "/bin/sh",
        "-c",
        "stty raw -echo; printf READY; sleep 0.1; head -c 262144 | wc -c",
      },
      cols = 80,
      rows = 4,
    }, function(t)
      for _ = 1, 600 do
        t:poll_events()
        if screen(t):find("READY", 1, true) then
          break
        end
        pause()
      end
      assert(t:write(string.rep("x", 262144)))
      for _ = 1, 1000 do
        t:poll_events()
        if t:exited() then
          break
        end
        pause()
      end
      assert(t:exited(), "large write did not finish")
      equal(t.pending_bytes, 0)
      assert(screen(t):find("262144", 1, true))
    end)
  end)
end
it(
  "runs commands interactively through the key encoder and reports PTY resize",
  function()
    with_terminal({
      command = windows and { "cmd.exe", "/d" } or { "/bin/sh", "-i" },
      env = {
        PS1 = "PGT_PROMPT> ",
        PROMPT = "PGT_PROMPT$G ",
        PGT_TEST = "OK",
        ENV = "",
      },
      cols = 80,
      rows = 8,
    }, function(t)

      ---@param text string Expected terminal output substring.
      local function wait_for(text)
        for _ = 1, 600 do
          t:poll_events()
          if screen(t):find(text, 1, true) then
            return
          end
          pause()
        end
        error("missing shell output: " .. text .. "\n" .. screen(t))
      end

      wait_for("PGT_PROMPT>")
      -- Recovery clears emulation state while retaining the live shell.
      local pid = pty.C.pgt_pty_pid(t.pty)
      t:feed("\27[?1049h\27[?1003h")
      t:reset()
      equal(pty.C.pgt_pty_pid(t.pty), pid)
      assert(not t:mouse_tracking())
      t:resize(93, 12, 8, 16)
      t:input_text(
        windows and "echo INTERACTIVE_%PGT_TEST%"
          or "printf 'INTERACTIVE_%s\\n' OK; stty size"
      )
      t:send_key { key = "return" }
      wait_for("INTERACTIVE_OK")
      if not windows then
        wait_for("12 93")
      end -- Windows resize is checked by the native transport suite.
      t:input_text(windows and "exit /b 0" or "exit 0")
      t:send_key { key = "return" }
      for _ = 1, 600 do
        t:poll_events()
        if t:exited() then
          break
        end
        pause()
      end
      local exited, code = t:exited()
      assert(exited)
      equal(code, 0)
    end)
  end
)
if not windows then
  it("reaps children that ignore hangup when the terminal is closed", function()
    local t = backend.new {
      command = {
        "/bin/sh",
        "-c",
        "trap '' HUP TERM; printf READY; while :; do sleep 1; done",
      },
    }
    for _ = 1, 300 do
      t:poll_events()
      if screen(t):find("READY", 1, true) then
        break
      end
      pause()
    end
    local pid = pty.C.pgt_pty_pid(t.pty)
    t:close()
    for _ = 1, 400 do
      if ffi.C.kill(pid, 0) ~= 0 then
        return
      end
      pause()
    end
    error("closed terminal left a child process behind")
  end)
end
it("rejects missing commands, invalid cwd and NUL arguments", function()
  assert(not pcall(backend.new, { command = { "/does/not/exist" } }))
  local shell = windows and "cmd.exe" or "/bin/sh"
  assert(
    not pcall(backend.new, { command = { shell }, cwd = "/does/not/exist" })
  )
  assert(not pcall(backend.new, { command = { shell, "\0" } }))
end)

it(
  "configures shell arguments and runs commands with environment overrides",
  function()
    with_terminal({
      shell = true,
      command = windows and "echo SHELL_%PGT_TEST%" or "printf SHELL_$PGT_TEST",
      environment = { PGT_TEST = "OVERRIDDEN" },
      env = { PGT_TEST = "FLAGS_OK" },
      cols = 80,
      rows = 4,
    }, function(t)
      for _ = 1, 600 do
        t:poll_events()
        if t:exited() then
          break
        end
        pause()
      end
      local exited, code = t:exited()
      assert(exited)
      equal(code, 0)
      assert(screen(t):find("SHELL_FLAGS_OK", 1, true))
    end)
  end
)
if not in_editor then
  print(count .. " backend tests passed")
end
