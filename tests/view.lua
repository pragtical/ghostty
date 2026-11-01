local test = require "core.test"
local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local renderer = require "renderer"
local system = require "system"
local source = debug.getinfo(1, "S").source:sub(2)
local root = source:match("^(.*)[/\\]tests[/\\]") or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
local ghostty = require "plugins.ghostty"
local click = require "plugins.ghostty.click_to_open"
local selection = require "plugins.ghostty.selection"
local palette = require "plugins.ghostty.palette"

---@param view plugins.ghostty.TerminalView
---@return string Queued terminal input, removed after reading.
local function sent(view)
  local t = view.terminal
  local text = table.concat(t.writes, "", t.write_head, t.write_tail)
  t.writes, t.write_head, t.write_tail, t.pending_bytes, t.write_offset =
    {}, 1, 0, 0, 0
  return text
end

---Add numbered history with enough rows to drag the scrollbar.
---@param view plugins.ghostty.TerminalView
local function fill_history(view)
  local lines = {}
  for i = 1, 100 do
    lines[i] = string.format("line%03d", i)
  end
  view.terminal:feed(table.concat(lines, "\r\n"))
  view:update()
end

---Let the polling worker drain output and apply the view's exit policy.
---@param view plugins.ghostty.TerminalView
local function wait_for_exit(view)
  local deadline = system.get_time() + 5
  while not view.exited and system.get_time() < deadline do
    coroutine.yield(0.01)
  end
  test.ok(view.exited, "Terminal did not exit before timeout")
end

---Wait for shell output while the editor continues polling the PTY.
---@param view plugins.ghostty.TerminalView
---@param text string Output that does not appear literally in the input echo.
local function wait_for_output(view, text)
  local deadline = system.get_time() + 5
  repeat
    if not view.terminal then break end
    local lines = {}
    for _, row in ipairs(view.terminal:update_render().rows_data) do
      lines[#lines + 1] = table.concat(row.cells)
    end
    if table.concat(lines, "\n"):find(text, 1, true) then return end
    coroutine.yield(0.01)
  until system.get_time() >= deadline
  test.ok(false, "Missing terminal output: " .. text)
end

---Use a predictable interactive shell without user startup scripts.
---@param context table Test context retaining the original configuration.
local function configure_test_shell(context)
  local windows = PLATFORM == "Windows"
  config.plugins.ghostty = common.merge(context.ghostty_config, {
    shell = windows and "cmd.exe" or "/bin/sh",
    arguments = windows and { "/d", "/q" } or { "-i" },
    env = { ENV = "", PGT_RUN_TEST = "OK" },
  })
end

---Build a command whose output differs from the terminal's input echo.
---@param prefix string Marker prefix.
---@return string command
local function print_marker(prefix)
  return PLATFORM == "Windows" and ("echo " .. prefix .. "%PGT_RUN_TEST%")
    or ("printf '" .. prefix .. "%s\\n' \"$PGT_RUN_TEST\"")
end

---Invoke a terminal command and retain its view for cleanup on test failure.
---@param context table Test context retaining additional views.
---@param action string Registered command name.
---@param text string Command to execute inside the shell.
---@return plugins.ghostty.TerminalView
local function run_in_terminal(context, action, text)
  test.ok(command.perform(action, text))
  local view = core.active_view
  test.ok(view.ghostty_terminal_view)
  table.insert(context.extra_views, view)
  view.size.x, view.size.y = 640, 240
  view:update()
  return view
end

test.describe("Ghostty Pragtical integration", function()
  test.before_each(function(context)
    context.active = core.active_view
    context.ghostty_config = config.plugins.ghostty
    context.extra_views = {}
    context.modkeys = keymap.modkeys
    context.mouse_x, context.mouse_y =
      core.root_view.mouse.x, core.root_view.mouse.y
    keymap.modkeys = {}
    context.view = ghostty.open_tab { command = false, close_on_exit = "never" }
    context.view.size.x, context.view.size.y = 640, 240
    context.view:update()
  end)

  test.after_each(function(context)
    if
      context.prompt_state
      and core.command_view.state ~= context.prompt_state
    then
      core.command_view:exit(false)
    end
    if context.unsubscribe_created then context.unsubscribe_created() end
    if context.saved_error then core.error = context.saved_error end
    if context.saved_shell then
      require("plugins.ghostty.config").shell = context.saved_shell
    end
    config.plugins.ghostty = context.ghostty_config
    if context.saved_style then
      for key, value in pairs(context.saved_style) do
        style[key] = value
      end
    end
    table.insert(context.extra_views, context.view)
    for _, view in ipairs(context.extra_views) do
      local node = core.root_view.root_node:get_node_for_view(view)
      if node then
        node:close_view(core.root_view.root_node, view)
      else
        view:close()
      end
    end
    if context.startup_dir then common.rm(context.startup_dir, true) end
    if context.active then
      core.set_active_view(context.active)
    end
    keymap.modkeys = context.modkeys
    core.root_view.mouse.x, core.root_view.mouse.y =
      context.mouse_x, context.mouse_y
    if context.wheel_keymap then
      keymap.map = context.wheel_keymap
    end
  end)

  test.it(
    "updates ANSI colors in existing terminals when the theme changes",
    function(context)
      context.saved_style = {
        syntax = style.syntax,
        background = style.background,
        text = style.text,
      }
      style.background, style.text = { 20, 20, 20 }, { 230, 230, 230 }
      style.syntax = { keyword = { 230, 95, 95 } }
      local view = context.view
      view.terminal:feed("\27[31mred\27[0m")
      view:update()
      test.equal(view.snapshot.rows_data[1].spans[1].fg[2], 95)
      style.syntax.keyword[2], style.syntax.keyword[3] = 130, 130
      view:update()
      test.equal(view.snapshot.rows_data[1].spans[1].fg[2], 130)
      local key = view.palette_key
      style.background, style.text = { 250, 250, 250 }, { 30, 30, 30 }
      view:update()
      test.ok(view.palette_key ~= key)
      test.equal(view.snapshot.background[1], 250)
      test.equal(view.terminal.options.background[1], 250)
      test.ok(view.snapshot.rows_data[1].spans[1].fg[1] < 230)
    end
  )

  test.it(
    "tracks theme channel edits and missing accents without string keys",
    function()
      local state, theme = {}, { syntax = { keyword = { 100, 150, 200 } } }
      local fg, bg = { 220, 220, 220 }, { 20, 20, 20 }
      test.ok(palette.changed(state, theme, fg, bg))
      test.ok(not palette.changed(state, theme, fg, bg))
      theme.syntax.keyword[4] = 80
      test.ok(palette.changed(state, theme, fg, bg))
      test.ok(not palette.changed(state, theme, fg, bg))
      theme.syntax.keyword = nil
      test.ok(palette.changed(state, theme, fg, bg))
      theme.syntax = nil
      test.ok(not palette.changed(state, theme, fg, bg))
      theme.accent = { 150, 100, 200 }
      test.ok(palette.changed(state, theme, fg, bg))
      fg[1], bg[3] = 210, 30
      test.ok(palette.changed(state, theme, fg, bg))
      test.ok(not palette.changed(state, theme, fg, bg))
    end
  )

  test.it(
    "opens a terminal tab in the current project and draws cell backgrounds",
    function(context)
      local view = context.view
      test.equal(view.cwd, core.root_project().path)
      view.terminal:feed("\27[?25l\27[41m  \27[1;3mBold\27[0m\r\n界é")
      view:update()
      test.equal(view.snapshot.rows_data[1].cells[1], " ")
      local old_rect, old_text = renderer.draw_rect, renderer.draw_text
      local rects, texts = {}, {}

      renderer.draw_rect = function(x, y, w, h, color)
        rects[#rects + 1] = { x, y, w, h, color }
      end

      renderer.draw_text = function(font, text, x, y, color)
        texts[#texts + 1] = { text, x, y, font }
        return x + font:get_width(text)
      end

      renderer.begin_frame(core.window)
      local ok, err = pcall(view.draw, view)
      renderer.end_frame()
      renderer.draw_rect, renderer.draw_text = old_rect, old_text
      test.ok(ok, err)
      -- One view background and one six-cell red run, including spaces.
      test.equal(#rects, 2)
      test.equal(rects[2][1], view.position.x)
      test.equal(rects[2][3], 6 * view.cell_width)
      test.equal(rects[2][5], view.snapshot.rows_data[1].spans[1].bg)
      test.equal(#texts, 6)
      test.equal(texts[1][1], "B")
      test.equal(texts[1][2], view.position.x + 2 * view.cell_width)
      test.equal(texts[1][4], view.bold_italic_font)
      test.equal(texts[5][1], "界")
      test.equal(texts[6][1], "é")
      test.equal(texts[6][2], view.position.x + 2 * view.cell_width)
      test.ok(view.bold_font and view.italic_font)
    end
  )

  test.it(
    "draws decorated spaces, selection and wide cursors with cached rows",
    function(context)
      local view = context.view
      view.terminal:feed("\27[4;9m  \27[0m界é\27[3G\27[2 q")
      view:update()
      view.focused = true
      selection.start(view.selection, 1, 1)
      selection.update(view.selection, 4, 1)
      local old_rect, old_text = renderer.draw_rect, renderer.draw_text
      local rects, texts = {}, {}

      renderer.draw_rect = function(x, y, w, h, color)
        rects[#rects + 1] = { x, y, w, h, color }
      end

      renderer.draw_text = function(font, text, x, y, color)
        texts[#texts + 1] = { text, x, y }
        return x + font:get_width(text)
      end

      local ok, err = pcall(function()
        -- The second draw uses the cached drawing row.
        for _ = 1, 2 do
          rects, texts = {}, {}
          renderer.begin_frame(core.window)
          view:draw()
          renderer.end_frame()
        end
      end)
      renderer.draw_rect, renderer.draw_text = old_rect, old_text
      test.ok(ok, err)
      test.equal(#rects, 7) -- Background, selection, four rules, block cursor.
      test.equal(rects[2][3], 4 * view.cell_width)
      test.equal(rects[2][5], style.selection)
      test.equal(rects[3][2], view.position.y + view.cell_height - 2)
      test.equal(rects[3][3], view.cell_width)
      test.equal(
        rects[4][2],
        view.position.y + math.floor(view.cell_height / 2)
      )
      test.equal(rects[7][1], view.position.x + 2 * view.cell_width)
      test.equal(rects[7][3], 2 * view.cell_width)
      test.equal(#texts, 3)
      test.equal(texts[1][1], "界")
      test.equal(texts[2][1], "é")
      test.equal(texts[2][2], view.position.x + 4 * view.cell_width)
      test.equal(texts[3][1], "界") -- Cursor redraws the entire wide glyph.
    end
  )

  test.it(
    "reuses drawing arrays and respects fractional fonts and resized grids",
    function(context)
      local view = context.view
      local size = style.code_font:get_size() + 0.25
      view.options.font = renderer.font.group {
        style.code_font:copy(size), style.code_font:copy(size),
      }
      view.terminal:feed("\27[?25l\27[1mA\27[0m界é")
      view:update()
      local original, calls = renderer.draw_text, {}

      renderer.draw_text = function(font, text, x, y, color)
        calls[#calls + 1] = { font = font, text = text, x = x, y = y }
        return original(font, text, x, y, color)
      end

      local ok, err = pcall(function()

        local function draw()
          calls = {}
          renderer.begin_frame(core.window)
          view:draw()
          renderer.end_frame()
        end

        draw()
        local rows, first = view.drawing_rows, view.drawing_rows[1]
        view.position.x = view.position.x + 7
        draw()
        test.equal(view.drawing_rows, rows)
        test.equal(view.drawing_rows[1], first)
        test.equal(calls[1].font, view.bold_font)
        test.equal(calls[2].x, view.position.x + view.cell_width)
        test.equal(calls[3].x, view.position.x + 3 * view.cell_width)
        test.equal(calls[3].text, "é")
        local bold = view.bold_font
        view.options.font:set_size(size + 2.5)
        view.size.y = 2 * view.options.font:get_height()
        view:update()
        draw()
        test.ok(view.bold_font ~= bold)
        test.equal(#view.drawing_rows, view.rows)
        test.equal(calls[2].x, view.position.x + view.cell_width)
        test.equal(calls[3].x, view.position.x + 3 * view.cell_width)
      end)
      renderer.draw_text = original
      test.ok(ok, err)
    end
  )

  test.it(
    "resets a terminal without sending mouse reports to the shell",
    function(c)
      local view = c.view
      view.terminal:feed("\27[?1049h\27[?1003h\27[?1006hbroken")
      view:update()
      local x, y = view.position.x + 10, view.position.y + 10
      view:on_mouse_pressed("left", x, y, 1)
      test.ok(#sent(view) > 0)
      keymap.modkeys.shift = true
      view:on_mouse_pressed("left", x, y, 2)
      test.ok(view.selection.active)
      keymap.modkeys.shift = nil
      view.pressed.a = { key = "a", text = "a" }
      view.pending_key = view.pressed.a
      test.ok(command.perform("ghostty:reset"))
      test.ok(not view.terminal:mouse_tracking())
      test.ok(not view.selection.active)
      test.ok(not view.selection.anchor)
      test.ok(not view.mouse_button)
      test.ok(not view.pending_key)
      test.equal(next(view.pressed), nil)
      test.equal(
        table.concat(view.snapshot.rows_data[1].cells):gsub(" ", ""),
        ""
      )
      view:on_mouse_released("left", x, y)
      view:on_mouse_moved(x + 1, y + 1, 1, 1)
      view:on_mouse_pressed("left", x, y, 1)
      test.ok(view.selection.active)
      view:on_mouse_released("left", x, y)
      test.equal(sent(view), "")
    end
  )

  test.it("scrolls history by clicking and dragging the scrollbar", function(c)
    local view = c.view
    fill_history(view)
    local bar = view.v_scrollbar
    local x, y, w, h = bar:get_track_rect()
    x = x + w / 2
    test.ok(view.scrollbar_visible)
    test.equal(bar.percent, 1)
    test.equal(view.scrollback_rows, 100 - view.rows)
    test.equal(
      view:get_scrollable_size(),
      view.size.y + (100 - view.rows) * view.cell_height
    )
    test.ok(view:on_mouse_pressed("left", x, y + 1, 1))
    view:update()
    test.equal(view.snapshot.scrollbar.offset, 0)
    test.match(table.concat(view.snapshot.rows_data[1].cells), "line001")
    test.ok(not view.selection.active)
    view:on_mouse_moved(x, y + h / 3, 0, h / 3)
    view:on_mouse_moved(x, y + h / 2, 0, h / 6)
    view:update()
    test.ok(math.abs(bar.percent - 0.5) < 0.01)
    test.equal(
      view.snapshot.scrollbar.offset,
      math.floor(view.scrollback_rows / 2 + 0.5)
    )
    view:on_mouse_moved(x, y + h + 100, 0, h)
    view:update()
    test.equal(bar.percent, 1)
    view:on_mouse_released("left", x, y + h + 100)
    test.ok(not bar.dragging)
    local _, ty, _, th = bar:get_thumb_rect()
    view:on_mouse_pressed("left", x, ty + th / 2, 1)
    view:on_mouse_moved(x, y - 100, 0, -h)
    view:update()
    test.equal(bar.percent, 0)
    view:on_mouse_released("left", x, y - 100)
    view:on_mouse_left()
    test.ok(not view:scrollbar_hovering())
    view.terminal:input_text("a")
    view:update()
    test.equal(bar.percent, 1)
    test.equal(sent(view), "a")
  end)

  test.it("keeps scrollbar gestures out of terminal mouse input", function(c)
    local view = c.view
    fill_history(view)
    view.terminal:feed("\27[?1003h\27[?1006h")
    view:update()
    local bar = view.v_scrollbar
    local x, y, w, h = bar:get_track_rect()
    x = x + w / 2
    keymap.modkeys[view.options.click_modifier] = true
    view:on_mouse_pressed("left", x, y + 1, 2)
    view:on_mouse_moved(x, y + h / 2, 0, h / 2)
    view:on_mouse_released("left", x, y + h / 2)
    view:update()
    test.equal(sent(view), "")
    test.ok(not selection.has_selection(view.selection))
    local offset = view.snapshot.scrollbar.offset
    core.root_view.mouse.x, core.root_view.mouse.y = x, y + h / 2
    view:on_mouse_wheel(1)
    view:update()
    test.equal(view.snapshot.scrollbar.offset, offset - 3)
    test.equal(sent(view), "")
    keymap.modkeys = {}
    local cx, cy = view.position.x + 5, view.position.y + 5
    view:on_mouse_pressed("left", cx, cy, 1)
    view:on_mouse_moved(x, y + h / 2, 0, 0)
    view:on_mouse_released("left", x, y + h / 2)
    test.match(sent(view), "\27%[<0;1;1M.*\27%[<32;.*m")
    keymap.modkeys.shift = true
    view:on_mouse_pressed("left", cx, cy, 1)
    view:on_mouse_moved(x, y + h / 2, 0, 0)
    view:on_mouse_released("left", x, y + h / 2)
    test.ok(selection.has_selection(view.selection))
    test.equal(sent(view), "")
  end)

  test.it("ignores wheel events outside the terminal bounds", function(c)
    local view = c.view
    view.position.x, view.position.y = 100, 100
    fill_history(view)
    local x, y, w, h =
      view.position.x, view.position.y, view.size.x, view.size.y
    -- The view's last mouse position can remain inside after the mouse leaves.
    view.mouse_x, view.mouse_y = x + 10, y + 10
    selection.start(view.selection, 1, 1, 4, 1)
    local selected, offset = view.selection, view.snapshot.scrollbar.offset
    for _, mode in ipairs { "l", "h" } do
      view.terminal:feed("\27[?1000" .. mode .. "\27[?1006h")
      for _, point in ipairs {
        { x - 1, y + 10 }, { x + w, y + 10 },
        { x + 10, y - 1 }, { x + 10, y + h },
      } do
        core.root_view.mouse.x, core.root_view.mouse.y = point[1], point[2]
        test.equal(view:on_mouse_wheel(1), false)
        test.equal(view:on_mouse_wheel(-1), false)
        test.equal(view.selection, selected)
        test.equal(view.terminal:update_render().scrollbar.offset, offset)
        test.equal(sent(view), "")
      end
    end
    core.root_view.mouse.x, core.root_view.mouse.y = x, y
    view.size.x = 0
    test.equal(view:on_mouse_wheel(1), false)
    view.size.x, view.size.y = w, 0
    test.equal(view:on_mouse_wheel(1), false)
  end)

  test.it("uses the current pointer for terminal wheel input", function(c)
    local view = c.view
    fill_history(view)
    local x, y = view.position.x, view.position.y
    -- A newly exposed view need not have received a mouse movement yet.
    view.mouse_x, view.mouse_y = x - 10, y - 10
    core.root_view.mouse.x, core.root_view.mouse.y = x, y
    local offset = view.snapshot.scrollbar.offset
    test.ok(view:on_mouse_wheel(1))
    test.equal(view.terminal:update_render().scrollbar.offset, offset - 3)
    view.terminal:feed("\27[?1000h\27[?1006h")
    core.root_view.mouse.x = x + 2 * view.cell_width + 1
    core.root_view.mouse.y = y + view.cell_height + 1
    test.ok(view:on_mouse_wheel(-1))
    test.equal(sent(view), "\27[<65;3;2M")
    keymap.modkeys.shift = true
    test.ok(view:on_mouse_wheel(1))
    test.equal(sent(view), "")
    test.equal(view.terminal:update_render().scrollbar.offset, offset - 6)
  end)

  test.it(
    "passes wheel bindings to the editor while a terminal has focus",
    function(c)
      local view = c.view
      local node = core.root_view.root_node:get_node_for_view(view)
      view.position.x, view.position.y =
        node.position.x, node.position.y + 100
      core.root_view.mouse.x = view.position.x + 10
      core.root_view.mouse.y = view.position.y - 1
      c.wheel_keymap = keymap.map
      keymap.map = setmetatable({}, { __index = keymap.map })
      for _, stroke in ipairs { "wheelup", "wheeldown", "wheelright" } do
        local received

        ---@param delta number
        keymap.map[stroke] = { function(delta)
          received = delta
        end }

        local vertical = stroke == "wheelright" and 0
          or (stroke == "wheelup" and 1 or -1)
        local horizontal = stroke == "wheelright" and -1 or 0
        core.on_event("mousewheel", vertical, horizontal)
        test.equal(received, vertical ~= 0 and vertical or horizontal)
        test.equal(sent(view), "")
      end
    end
  )

  test.it(
    "updates the scrollbar for output, resize and screen changes",
    function(c)
      local view = c.view
      test.ok(not view.scrollbar_visible)
      test.ok(not view:scrollbar_overlaps_point(0, 0))
      fill_history(view)
      view.terminal:feed("\r\nnew output")
      view:update()
      test.equal(view.v_scrollbar.percent, 1)
      view.terminal:scroll_to(10)
      view:update()
      local top = table.concat(view.snapshot.rows_data[1].cells)
      view.terminal:feed("\r\nmore output")
      view:update()
      test.equal(table.concat(view.snapshot.rows_data[1].cells), top)
      test.equal(view.snapshot.scrollbar.offset, 10)
      local cols = view.cols
      view.size.y = view.size.y * 2
      view:update()
      test.equal(view.cols, cols)
      test.equal(view.snapshot.scrollbar.len, view.rows)
      local bar = view.v_scrollbar
      local x, y, w, h = bar:get_thumb_rect()
      view:on_mouse_pressed("left", x + w / 2, y + h / 2, 1)
      view.terminal:feed("\27[?1049h\27[?1003h\27[?1006h")
      view:update()
      test.ok(not view.scrollbar_visible)
      test.ok(not bar.dragging)
      test.equal(bar.percent, 0)
      view:on_mouse_moved(x, y, 0, 0)
      view:on_mouse_released("left", x, y)
      test.equal(sent(view), "")
      view.terminal:feed("\27[?1049l")
      view:update()
      test.ok(view.scrollbar_visible)
      view.size.y = 8 -- Smaller than the core widget's minimum thumb size.
      view:update()
      x, y, w, h = bar:get_track_rect()
      view:on_mouse_pressed("left", x + w / 2, y, 1)
      view:on_mouse_moved(x + w / 2, y + h, 0, h)
      view:on_mouse_released("left", x + w / 2, y + h)
      view:update()
      test.equal(bar.percent, 1)
      view.size.y = 0
      view:update()
      test.ok(not view.scrollbar_visible)
      view.size.y = 240
      view:update()
      test.ok(view.scrollbar_visible)
      view.terminal:feed("\27[3J") -- Erase saved lines.
      view:update()
      test.ok(not view.scrollbar_visible)
      test.equal(view:get_scrollable_size(), view.size.y)
    end
  )

  test.it(
    "forwards text and repeated text once and preserves terminal control keys",
    function(context)
      local view = context.view
      keymap.on_key_pressed("a")
      view:on_text_input("a")
      keymap.on_key_pressed("a")
      view:on_text_input("a")
      keymap.on_key_released("a")
      test.equal(sent(view), "aa")
      keymap.on_key_pressed("left ctrl")
      keymap.on_key_pressed("c")
      keymap.on_key_released("c")
      keymap.on_key_released("left ctrl")
      test.equal(sent(view), "\3")
      keymap.on_key_pressed("f5")
      keymap.on_key_released("f5")
      test.equal(sent(view), "\27[15~")
    end
  )

  test.it(
    "forwards shifted punctuation and repeats as text with the Kitty protocol",
    function(context)
      local view = context.view
      view.terminal:feed("\27[>1u")
      keymap.on_key_pressed("left shift")
      for _, pair in ipairs {
        { ";", ":" },
        { "'", '"' },
        { "1", "!" },
        { "/", "?" },
        { "a", "A" },
      } do
        keymap.on_key_pressed(pair[1])
        view:on_text_input(pair[2])
        keymap.on_key_pressed(pair[1])
        view:on_text_input(pair[2])
        keymap.on_key_released(pair[1])
        test.equal(sent(view), pair[2] .. pair[2])
      end
      keymap.on_key_pressed("tab")
      keymap.on_key_released("tab")
      test.equal(sent(view), "\27[9;2u")
      keymap.on_key_released("left shift")
      keymap.on_key_pressed(";")
      view:on_text_input(";")
      keymap.on_key_released(";")
      test.equal(sent(view), ";")
    end
  )

  test.it(
    "forwards Space once per press or repeat and encodes its release",
    function(context)
      local view = context.view
      for _, flags in ipairs { 0, 1, 3, 7, 31 } do
        view.terminal:feed("\27[=" .. flags .. "u")
        keymap.on_key_pressed("space")
        view:on_text_input(" ")
        test.equal(sent(view), flags == 31 and "\27[32;;32u" or " ")
        keymap.on_key_pressed("space")
        view:on_text_input(" ")
        test.equal(sent(view), flags == 31 and "\27[32;1:2;32u" or " ")
        keymap.on_key_released("space")
        test.equal(sent(view), flags >= 3 and "\27[32;1:3u" or "")
      end
      view.terminal:feed("\27[=3u")
      keymap.on_key_pressed("left shift")
      keymap.on_key_pressed("space")
      view:on_text_input(" ")
      test.equal(sent(view), "\27[32;2u")
      keymap.on_key_released("space")
      test.equal(sent(view), "\27[32;2:3u")
      keymap.on_key_released("left shift")
      keymap.on_key_pressed("left ctrl")
      keymap.on_key_pressed("space")
      test.equal(sent(view), "\27[32;5u")
      keymap.on_key_released("space")
      test.equal(sent(view), "\27[32;5:3u")
      keymap.on_key_released("left ctrl")
    end
  )

  test.it(
    "keeps editor copy bindings and provides terminal copy selection",
    function(context)
      test.ok(keymap.map["ctrl+c"] and #keymap.map["ctrl+c"] > 0)
      local view = context.view
      view.terminal:feed("aé界z")
      selection.start(view.selection, 2, 1)
      selection.update(view.selection, 4, 1)
      selection.finish(view.selection)
      local previous = system.get_clipboard()
      test.ok(command.perform("ghostty:copy-selection"))
      test.equal(system.get_clipboard(), "é界")
      system.set_clipboard(previous or "")
    end
  )

  test.it("selects the word under the cursor on double click", function(c)
    local view = c.view
    view.terminal:feed("foo bar/baz  qux")
    view:update()

    ---@param col integer
    ---@param clicks integer
    local function press(col, clicks)
      local x = view.position.x + (col - 0.5) * view.cell_width
      local y = view.position.y + view.cell_height / 2
      return view:on_mouse_pressed("left", x, y, clicks)
    end

    test.ok(press(2, 2)) -- Inside "foo".
    local first, last = selection.range(view.selection)
    test.equal(first.col, 1)
    test.equal(last.col, 3)
    test.ok(view.selection.active)
    view:on_mouse_released("left", 0, 0)
    test.ok(not view.selection.active)
    test.ok(selection.has_selection(view.selection))

    test.ok(press(6, 2)) -- Ghostty keeps paths together.
    first, last = selection.range(view.selection)
    test.equal(first.col, 5)
    test.equal(last.col, 11)
    view:on_mouse_released("left", 0, 0)

    test.ok(press(9, 2)) -- Inside "baz".
    first, last = selection.range(view.selection)
    test.equal(first.col, 5)
    test.equal(last.col, 11)
    view:on_mouse_released("left", 0, 0)

    test.ok(press(30, 2)) -- Unwritten cell: plain click, no selection.
    test.ok(view.selection.active)
    view:on_mouse_released("left", 0, 0)
    test.ok(not selection.has_selection(view.selection))

    test.ok(press(2, 3)) -- Higher click counts keep ordinary click behavior.
    view:on_mouse_released("left", 0, 0)
    test.ok(not selection.has_selection(view.selection))

    test.ok(press(2, 1)) -- Single click still starts a drag selection.
    test.ok(view.selection.active)
    view:on_mouse_released("left", 0, 0)
    test.ok(not selection.has_selection(view.selection))

    view.terminal:feed("\r\n界ab\27[3G") -- Wide glyph and its spacer cell.
    view:update()
    local y = view.position.y + 1.5 * view.cell_height
    local x = view.position.x + 1.5 * view.cell_width
    test.ok(view:on_mouse_pressed("left", x, y, 2))
    first, last = selection.range(view.selection)
    test.equal(first.row, 2)
    test.equal(first.col, 1)
    test.equal(last.col, 4)
    local previous = system.get_clipboard()
    test.ok(command.perform("ghostty:copy-selection"))
    test.equal(system.get_clipboard(), "界ab")
    system.set_clipboard(previous or "")
  end)

  test.it("keeps modified link clicks ahead of word selection", function(c)
    local view = c.view
    view.terminal:feed("\27]8;;https://example.com\27\\link\27]8;;\27\\")
    view:update()
    local opened, old_open = nil, click.open

    ---@param target table
    click.open = function(target)
      opened = target
      return true
    end

    local ok, err = pcall(function()
      keymap.modkeys[view.options.click_modifier] = true
      local x = view.position.x + 1.5 * view.cell_width
      local y = view.position.y + view.cell_height / 2
      view:on_mouse_pressed("left", x, y, 2)
      view:on_mouse_released("left", x, y)
      test.equal(opened.target, "https://example.com")
      test.ok(not selection.has_selection(view.selection))
    end)
    click.open = old_open
    test.ok(ok, err)
  end)

  test.it("extends a double-click selection in either direction", function(c)
    local view = c.view
    view.terminal:feed("one foo_bar end x")
    view:update()
    local y = view.position.y + view.cell_height / 2
    local x = view.position.x + 5.5 * view.cell_width
    view:on_mouse_pressed("left", x, y, 2)
    view:on_mouse_moved(x, y, 0, 0) -- Pointer jitter keeps the whole word.
    local first, last = selection.range(view.selection)
    test.equal(first.col, 5)
    test.equal(last.col, 11)
    view:on_mouse_moved(x + 8 * view.cell_width, y, 8 * view.cell_width, 0)
    first, last = selection.range(view.selection)
    test.equal(first.col, 5)
    test.equal(last.col, 14)
    view:on_mouse_moved(x - 4 * view.cell_width, y, -12 * view.cell_width, 0)
    first, last = selection.range(view.selection)
    test.equal(first.col, 2)
    test.equal(last.col, 11)
    view:on_mouse_moved(x, y, 4 * view.cell_width, 0)
    first, last = selection.range(view.selection)
    test.equal(first.col, 5)
    test.equal(last.col, 11)
    view:on_mouse_released("left", x, y)
    test.ok(not view.selection.active)
    x = view.position.x + 16.5 * view.cell_width
    view:on_mouse_pressed("left", x, y, 2)
    view:on_mouse_released("left", x, y)
    first, last = selection.range(view.selection)
    test.equal(first.col, 17) -- A one-cell word survives release.
    test.equal(last.col, 17)
  end)

  test.it(
    "keeps double click in terminal mouse input unless Shift is held",
    function(c)
      local view = c.view
      view.terminal:feed("word more\27[?1003h\27[?1006h")
      view:update()
      local x = view.position.x + 1.5 * view.cell_width
      local y = view.position.y + view.cell_height / 2
      test.ok(view:on_mouse_pressed("left", x, y, 2))
      view:on_mouse_released("left", x, y)
      test.equal(sent(view), "\27[<0;2;1M\27[<0;2;1m")
      test.ok(not selection.has_selection(view.selection))
      keymap.modkeys.shift = true
      test.ok(view:on_mouse_pressed("left", x, y, 2))
      test.equal(sent(view), "")
      keymap.modkeys.shift = nil
      -- Releasing Shift during selection must not resume terminal events.
      view:on_mouse_moved(x, y, 0, 0)
      view:on_mouse_released("left", x, y)
      test.equal(sent(view), "")
      local first, last = selection.range(view.selection)
      test.equal(first.col, 1)
      test.equal(last.col, 4)
      keymap.modkeys.shift = true
      view:on_mouse_pressed("left", x, y, 2)
      view:on_mouse_released("left", x, y)
      test.equal(sent(view), "") -- Also consume release while Shift is held.
    end
  )

  test.it(
    "updates terminal title and working directory from OSC",
    function(context)
      local view = context.view
      view.terminal:feed("\27]2;build log\7\27]7;file://localhost/tmp/a%20b\7")
      view:poll()
      test.equal(view:get_name(), "build log")
      test.equal(view.cwd, "/tmp/a b")
    end
  )

  test.it(
    "runs each tab command in a new shell that accepts further input",
    function(context)
      configure_test_shell(context)
      local previous
      for _, marker in ipairs { "FIRST_", "SECOND_" } do
        local view = run_in_terminal(context, "ghostty:run-command-in-tab",
          print_marker(marker))
        test.ok(view ~= previous)
        wait_for_output(view, marker .. "OK")
        local terminal = view.terminal
        view:on_text_input(print_marker("FOLLOWUP_"))
        terminal:send_key { key = "return" }
        wait_for_output(view, "FOLLOWUP_OK")
        test.equal(view.terminal, terminal)
        test.ok(not terminal:exited())
        previous = view
      end
    end
  )

  test.it("reuses and reveals the drawer with its shell state", function(c)
    configure_test_shell(c)
    local action = "ghostty:run-command-in-drawer"
    local view = run_in_terminal(c, action, print_marker("DRAWER_"))
    wait_for_output(view, "DRAWER_OK")
    local terminal = view.terminal
    view:on_text_input(PLATFORM == "Windows" and 'set "PGT_RUN_TEST=KEPT"'
      or "PGT_RUN_TEST=KEPT")
    terminal:send_key { key = "return" }
    test.ok(command.perform("ghostty:toggle-drawer"))
    test.ok(core.active_view ~= view)
    local reopened = run_in_terminal(c, action, print_marker("REUSED_"))
    test.equal(reopened, view)
    test.equal(view.terminal, terminal)
    test.ok(view.size.y > 0)
    wait_for_output(view, "REUSED_KEPT")
    test.ok(not terminal:exited())
  end)

  test.it("recreates an exited drawer before running a command", function(c)
    configure_test_shell(c)
    config.plugins.ghostty.close_on_exit = "never"
    local action = "ghostty:run-command-in-drawer"
    local old = run_in_terminal(c, action, "exit 7")
    wait_for_exit(old)
    test.not_nil(old.terminal)
    local view = run_in_terminal(c, action, print_marker("RECREATED_"))
    test.ok(view ~= old)
    test.is_nil(old.terminal)
    test.is_nil(core.root_view.root_node:get_node_for_view(old))
    wait_for_output(view, "RECREATED_OK")
    test.ok(not view.terminal:exited())
  end)

  test.it("prompts for commands and ignores blank input", function(c)
    configure_test_shell(c)
    c.prompt_state = core.command_view.state
    c.unsubscribe_created = ghostty.on("terminal-created", function(event)
      table.insert(c.extra_views, event.view)
    end)
    for _, target in ipairs { "tab", "drawer" } do
      local action = "ghostty:run-command-in-" .. target
      local count = #c.extra_views
      test.ok(command.perform(action))
      test.equal(#c.extra_views, count)
      core.command_view:exit(false)
      test.equal(#c.extra_views, count)
      for _, blank in ipairs { "", "  \t" } do
        test.ok(command.perform(action, blank))
        test.equal(#c.extra_views, count)
      end
      test.ok(command.perform(action))
      core.command_view:set_text("   ")
      core.command_view:submit()
      test.equal(#c.extra_views, count)
      test.ok(command.perform(action))
      core.command_view:set_text(print_marker("PROMPT_"))
      core.command_view:submit()
      test.equal(#c.extra_views, count + 1)
      local view = c.extra_views[#c.extra_views]
      test.equal(core.active_view, view)
      view.size.x, view.size.y = 640, 240
      view:update()
      wait_for_output(view, "PROMPT_OK")
    end
  end)

  test.it("reports rejected command input without sending Enter", function(c)
    local view = ghostty.open_drawer {
      command = false, write_limit = 4, close_on_exit = "never",
    }
    table.insert(c.extra_views, view)
    local errors = {}
    c.saved_error = core.error

    core.error = function(format, ...)
      errors[#errors + 1] = string.format(format, ...)
    end

    test.ok(command.perform("ghostty:run-command-in-drawer", "too long"))
    test.equal(sent(view), "")
    test.match(errors[#errors], "queue is full")
    test.ok(command.perform("ghostty:run-command-in-drawer", "1234"))
    test.equal(sent(view), "1234")
    test.match(errors[#errors], "Cannot send Enter")
  end)

  test.it(
    "closes manual tabs and drawers after successful and failed shell exits",
    function(context)
      local windows = PLATFORM == "Windows"
      for _, action in ipairs { "ghostty:open-tab", "ghostty:open-drawer" } do
        for _, code in ipairs { 0, 1 } do
          test.ok(command.perform(action, {
            shell = windows and "cmd.exe" or "/bin/sh",
            arguments = windows and { "/d", "/q" } or { "-i" },
            env = { ENV = "" },
          }))
          local view = core.active_view
          test.ok(view ~= context.view and view.ghostty_terminal_view)
          table.insert(context.extra_views, view)
          -- Plain exit inherits the previous command's status.
          view:on_text_input(windows and ("cmd /d /c exit " .. code)
            or (code == 0 and "true" or "false"))
          view.terminal:send_key { key = "return" }
          view:on_text_input("exit")
          view.terminal:send_key { key = "return" }
          wait_for_exit(view)
          test.equal(view.exit_code, code)
          test.equal(view.exit_signal, 0)
          test.is_nil(view.terminal)
          test.is_nil(core.root_view.root_node:get_node_for_view(view))
        end
      end
    end
  )

  test.it(
    "finds Spawn Agent commands added to PATH by interactive shell startup",
    function(context)
      test.skip_if(PLATFORM == "Windows", "Requires a POSIX shell")
      local probe = assert(io.popen("command -v zsh"))
      local executable = probe:read("*l")
      probe:close()
      test.skip_if(not executable, "Zsh is not installed")

      local dir = core.temp_filename("-agent-startup")
      test.ok(system.mkdir(dir))
      context.startup_dir = dir
      local rc = assert(io.open(dir .. "/.zshrc", "w"))
      rc:write('export PATH="$ZDOTDIR:$PATH"\n')
      rc:close()
      local tool_path = dir .. "/pgt-agent-startup-test"
      local tool = assert(io.open(tool_path, "w"))
      tool:write("#!/bin/sh\nprintf 'AGENT_%s\\n' STARTUP_OK\n")
      tool:close()
      local shell = require "plugins.ghostty.shell"
      local ok = os.execute("chmod +x " .. shell.quote_path(tool_path))
      test.ok(ok == true or ok == 0)

      local shell_config = require "plugins.ghostty.config"
      context.saved_shell = shell_config.shell
      shell_config.shell = executable
      config.plugins.ghostty = common.merge(context.ghostty_config, {
        env = { ZDOTDIR = dir },
      })
      config.plugins.ghostty.arguments = nil
      local view = run_in_terminal(
        context, "ghostty:spawn-agent", "pgt-agent-startup-test"
      )
      wait_for_exit(view)
      test.equal(view.exit_code, 0)
      wait_for_output(view, "AGENT_STARTUP_OK")
      test.not_nil(core.root_view.root_node:get_node_for_view(view))
    end
  )

  test.it(
    "keeps Spawn Agent views open after successful and failed exits",
    function(context)
      config.plugins.ghostty = common.merge(context.ghostty_config, {
        shell = PLATFORM == "Windows" and "cmd.exe" or "/bin/sh",
        arguments = {},
      })
      for _, code in ipairs { 0, 7 } do
        test.ok(command.perform("ghostty:spawn-agent", "exit " .. code))
        local view = core.active_view
        table.insert(context.extra_views, view)
        wait_for_exit(view)
        test.equal(view.exit_code, code)
        test.not_nil(view.terminal)
        test.not_nil(core.root_view.root_node:get_node_for_view(view))
      end
    end
  )

  test.it(
    "applies changed exit policies to new views and honors view overrides",
    function(context)
      local cases = {
        { ghostty.open_tab { command = false }, true },
        { ghostty.open_tab { command = false, kind = "agent" }, false },
      }
      for _, case in ipairs(cases) do
        table.insert(context.extra_views, case[1])
      end
      config.plugins.ghostty = common.merge(context.ghostty_config, {
        close_on_exit = "never",
        agent_close_on_exit = "always",
      })
      for _, case in ipairs {
        { {}, false },
        { { kind = "agent" }, true },
        { { kind = "agent", close_on_exit = "never" }, false },
        { { close_on_exit = "always" }, true },
      } do
        local view =
          ghostty.open_tab(common.merge(case[1], { command = false }))
        table.insert(context.extra_views, view)
        table.insert(cases, { view, case[2] })
      end
      for _, case in ipairs(cases) do
        local view, should_close = case[1], case[2]
        view.terminal:emit { kind = "terminal-exited", code = 7, signal = 0 }
        view:poll()
        test.equal(view.terminal == nil, should_close)
        local node = core.root_view.root_node:get_node_for_view(view)
        test.equal(node == nil, should_close)
      end
    end
  )

  test.it(
    "keeps failed sessions open under clean_exit policy",
    function(context)
      local view = ghostty.open_tab {
        command = false, close_on_exit = "clean_exit",
      }
      table.insert(context.extra_views, view)
      view.terminal:emit { kind = "terminal-exited", code = 7, signal = 0 }
      view:poll()
      test.not_nil(view.terminal)
      view.terminal:emit { kind = "terminal-exited", code = 0, signal = 0 }
      view:poll()
      test.is_nil(view.terminal)
      test.is_nil(core.root_view.root_node:get_node_for_view(view))
    end
  )

  test.it("removes the tab when the close command is used", function(context)
    test.ok(command.perform("ghostty:close-terminal"))
    test.is_nil(context.view.terminal)
    test.is_nil(core.root_view.root_node:get_node_for_view(context.view))
  end)

  test.it(
    "opens and hides a drawer while its process continues to run",
    function()
      local argv = PLATFORM == "Windows"
          and { "cmd.exe", "/d", "/s", "/c", "echo HIDDEN_OUTPUT" }
        or { "/bin/sh", "-c", "sleep 0.05; printf HIDDEN_OUTPUT" }
      local view =
        ghostty.open_drawer { command = argv, close_on_exit = "never" }
      test.ok(command.perform("ghostty:toggle-drawer"))
      local deadline = system.get_time() + 3
      while not view.exited and system.get_time() < deadline do
        coroutine.yield(0.01)
      end
      test.ok(view.exited)
      keymap.on_key_pressed("left shift")
      keymap.on_key_pressed("left alt")
      for _ = 1, 2 do
        keymap.on_key_pressed("t")
        keymap.on_key_released("t")
        test.equal(core.active_view, view)
      end
      keymap.on_key_released("left alt")
      keymap.on_key_released("left shift")
      view.size.x, view.size.y = 640, 240
      view:update()
      local lines = {}
      for _, row in ipairs(view.snapshot.rows_data) do
        lines[#lines + 1] = table.concat(row.cells)
      end
      test.match(table.concat(lines, "\n"), "HIDDEN_OUTPUT")
      command.perform("ghostty:close-terminal")
    end
  )

  test.it(
    "handles file URLs and file:line:column without shell interpolation",
    function()
      test.equal(click.resolve_file("~/a b", "/project"), HOME .. "/a b")
      test.equal(
        click.resolve_file("file://localhost/tmp/a%20b", "/project"),
        "/tmp/a b"
      )
      test.is_nil(click.resolve_file("ssh://host/path", "/project"))
      local target = click.detect("src/main.lua:12:4", 6)
      test.equal(target.target, "src/main.lua")
      test.equal(target.line, 12)
      test.equal(target.col, 4)
      test.equal(
        click.resolve_file(target.target, "/project"),
        "/project/src/main.lua"
      )
      local windows = click.detect([[C:\project\main.lua:12:4]], 8)
      test.equal(windows.target, [[C:\project\main.lua]])
      test.equal(windows.line, 12)
      test.equal(windows.col, 4)
      test.equal(click.resolve_file(windows.target, "/project"), windows.target)
      if PLATFORM == "Windows" then
        test.equal(click.decode_file_uri("file:///C:/a%20b"), "C:/a b")
        test.equal(
          click.decode_file_uri("file://server/share/a%20b"),
          "//server/share/a b"
        )
      end
    end
  )

  test.it(
    "opens the configured shell with startup flags and inherited environment",
    function()
      local shell = PLATFORM == "Windows" and "cmd.exe" or "/bin/sh"
      local arguments = PLATFORM == "Windows"
          and { "/d", "/s", "/c", "echo DEFAULT_%PGT_TEST%" }
        or { "-c", "printf DEFAULT_$PGT_TEST" }
      local view = ghostty.open_tab {
        shell = shell,
        arguments = arguments,
        environment = { PGT_TEST = "SHELL_OK" },
        close_on_exit = "never",
      }
      view.size.x, view.size.y = 640, 240
      local deadline = system.get_time() + 5
      while not view.exited and system.get_time() < deadline do
        coroutine.yield(0.01)
      end
      local exited, code = view.exited, view.exit_code
      view:update()
      local lines = {}
      for _, row in ipairs(view.snapshot.rows_data) do
        lines[#lines + 1] = table.concat(row.cells)
      end
      local node = core.root_view.root_node:get_node_for_view(view)
      node:close_view(core.root_view.root_node, view)
      test.ok(exited)
      test.equal(code, 0)
      test.match(table.concat(lines, "\n"), "DEFAULT_SHELL_OK")
    end
  )
end)
