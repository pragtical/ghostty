local test = require "core.test"
local core = require "core"
local command = require "core.command"
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

test.describe("Ghostty Pragtical integration", function()
  test.before_each(function(context)
    context.active = core.active_view
    context.modkeys = keymap.modkeys
    keymap.modkeys = {}
    context.view = ghostty.open_tab { command = false, close_on_exit = "never" }
    context.view.size.x, context.view.size.y = 640, 240
    context.view:update()
  end)

  test.after_each(function(context)
    if context.saved_style then
      for key, value in pairs(context.saved_style) do
        style[key] = value
      end
    end
    local view = context.view
    local node = core.root_view.root_node:get_node_for_view(view)
    if node then
      node:close_view(core.root_view.root_node, view)
    else
      view:close()
    end
    if context.active then
      core.set_active_view(context.active)
    end
    keymap.modkeys = context.modkeys
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
    "keeps failed sessions open under clean_exit policy",
    function(context)
      local view = context.view
      view.close_on_exit = "clean_exit"
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
