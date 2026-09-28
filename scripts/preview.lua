-- Run: SDL_VIDEO_DRIVER=dummy pragtical run scripts/preview.lua
local source = debug.getinfo(1, "S").source:sub(2)
local root = source:match("^(.*)[/\\]scripts[/\\]") or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
local core = require "core"
local renderer = require "renderer"
local renwindow = require "renwindow"
local window = renwindow.create("Ghostty Terminal", 960, 460)
local view = require("plugins.ghostty").new_terminal { command = false }
view.position.x, view.position.y = 20, 20
view.size.x, view.size.y = 920, 420
view:update()
local palette_rows = {}
for _, first in ipairs { 40, 100 } do
  local swatches = {}
  for i = 0, 7 do
    swatches[#swatches + 1] = string.format("\27[%dm      \27[0m ", first + i)
  end
  palette_rows[#palette_rows + 1] = table.concat(swatches) .. "\r\n"
end
view.terminal:feed(table.concat({
  "\27[1;36mPragtical · Ghostty Terminal\27[0m\r\n",
  "Direct LuaJIT FFI to libghostty-vt\r\n\r\n",
  "\27[32m~/project\27[0m $ printf 'hello terminal\\n'\r\n",
  "hello terminal\r\n\r\n",
  "\27[1mBold\27[0m  \27[3mItalic\27[0m  \27[4mUnderline\27[0m  "
    .. "\27[9mStrike\27[0m  \27[7mInverse\27[0m\r\n",
  "ANSI palette from the current theme:\r\n",
  table.concat(palette_rows),
  "\r\n",
  "UTF-8: café · Ελληνικά · 界 · é\r\n",
  "\27]8;;https://ghostty.org\27\\\27[4;34mghostty.org\27[0m"
    .. "\27]8;;\27\\\r\n\r\n",
  "\27[32m~/project\27[0m $ ",
}))
view:update()
view.focused = true
renderer.begin_frame(window)
core.clip_rect_stack = { { 0, 0, 960, 460 } }
renderer.draw_rect(0, 0, 960, 460, require("core.style").background)
view:draw()
renderer.end_frame()
local capture = renderer.to_canvas(window, 0, 0, 960, 460)
assert(capture:save_image("/tmp/pragtical-ghostty-preview.png"))
view:close()
print("Saved /tmp/pragtical-ghostty-preview.png")
