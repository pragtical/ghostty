-- Run inside Pragtical to use its bundled jit.p and the actual renderer.
-- See AGENTS.md for capture/replay commands and environment options.
local source = debug.getinfo(1, "S").source:sub(2)
local root = source:match("^(.*)[/\\]scripts[/\\]") or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
local core = require "core"
local renderer = require "renderer"
local renwindow = require "renwindow"
local system = require "system"
local profiler = require "jit.p"
assert(
  not package.loaded["plugins.ghostty"],
  "Use a fresh PRAGTICAL_USERDIR to avoid profiling an installed plugin"
)
local ghostty = require "plugins.ghostty"
local mode = os.getenv("GHOSTTY_PROFILE_MODE") or "capture"
local prefix = os.getenv("GHOSTTY_PROFILE_OUTPUT") or "/tmp/ghostty-profile"
local recording = os.getenv("GHOSTTY_PROFILE_INPUT") or prefix .. ".frames"
local repeats = tonumber(os.getenv("GHOSTTY_PROFILE_REPEATS")) or 10
assert(repeats >= 1 and repeats % 1 == 0, "repeats must be a positive integer")
local width, height = 1600, 900
local frames, samples = {}, {}
local view, window
local trace_file = os.getenv("GHOSTTY_PROFILE_TRACE")
if trace_file then
  require("jit.v").start(trace_file)
end

---@param name string Measured phase.
---@param elapsed number Seconds.
local function sample(name, elapsed)
  local values = samples[name] or {}
  samples[name] = values
  values[#values + 1] = elapsed * 1000
end

---@param command table|false Process argv or an emulation-only terminal.
local function create_view(command)
  window = window or renwindow.create("Ghostty profile", width, height)
  view = ghostty.new_terminal { command = command, close_on_exit = "never" }
  view.size.x, view.size.y = width, height
  view:update()
end

---Submit and render a complete terminal frame, including the native renderer.
---@param measure? boolean False for warmup and call counting.
local function draw(measure)
  local start = system.get_time()
  view:update()
  local updated = system.get_time()
  renderer.begin_frame(window)
  core.clip_rect_stack = { { 0, 0, width, height } }
  view:draw()
  local submitted = system.get_time()
  renderer.end_frame()
  if measure ~= false then
    sample("snapshot", updated - start)
    sample("draw", submitted - updated)
    sample("present", system.get_time() - submitted)
    sample("frame", system.get_time() - start)
  end
end

---Capture real btop output while alternating held Down and Up keys at 30 Hz.
local function capture()
  local config = assert(io.open(prefix .. ".btop.conf", "w"))
  config:write('proc_sorting = "pid"\nupdate_ms = 10000\n')
  config:close()
  create_view { "btop", "--config", prefix .. ".btop.conf", "--force-utf" }
  local chunks, feed = {}, view.terminal.feed

  ---@param terminal table
  ---@param data string
  view.terminal.feed = function(terminal, data)
    chunks[#chunks + 1] = data
    feed(terminal, data)
  end

  jit.off(view.terminal.feed, true)
  local start, next_key, keys = system.get_time(), 1, 0
  local seconds = tonumber(os.getenv("GHOSTTY_PROFILE_SECONDS")) or 8
  assert(seconds >= 2, "capture needs at least two seconds")
  while system.get_time() - start < seconds do
    local now = system.get_time()
    if now - start >= next_key then
      local key = math.floor(keys / 45) % 2 == 0 and "down" or "up"
      view.terminal:send_key { key = key, repeated = keys % 45 ~= 0 }
      keys, next_key = keys + 1, next_key + 1 / 30
    end
    for _, event in ipairs(view.terminal:poll_events()) do
      assert(event.kind ~= "terminal-exited", "btop exited during capture")
    end
    if #chunks > 0 then
      frames[#frames + 1] = table.concat(chunks)
      chunks = {}
      draw()
    end
    system.sleep(math.max(0, 1 / 60 - (system.get_time() - now)))
  end
  assert(#frames > 10, "btop did not produce enough frames")
  local file = assert(io.open(recording, "wb"))
  file:write(width, " ", height, "\n")
  for _, data in ipairs(frames) do
    file:write(#data, "\n", data)
  end
  file:close()
  print(string.format("Captured %d frames, %d keys", #frames, keys))
end

---Replay identical VT bytes without sleeps or a running btop process.
local function replay()
  local file = assert(io.open(recording, "rb"))
  local w, h = assert(file:read("*l")):match("^(%d+) (%d+)$")
  width, height = assert(tonumber(w)), assert(tonumber(h))
  assert(
    width > 0 and height > 0 and width <= 4096 and height <= 4096,
    "invalid recording size"
  )
  local line = file:read("*l")
  while line do
    local size = assert(tonumber(line))
    assert(size > 0 and size <= 32 * 1024 * 1024, "invalid frame size")
    local data = assert(file:read(size))
    assert(#data == size, "truncated recording")
    frames[#frames + 1] = data
    line = file:read("*l")
  end
  file:close()
  assert(#frames > 0, "empty recording")
  create_view(false)
  -- Warm the Lua traces and font glyph caches before collecting samples.
  for _, data in ipairs(frames) do
    view.terminal:feed(data)
    draw(false)
  end
  view:close()
  samples = {}
  profiler.start(
    os.getenv("GHOSTTY_PROFILE_FORMAT") or "fl3i1m1",
    prefix .. ".jit.txt"
  )
  for _ = 1, repeats do
    create_view(false)
    for _, data in ipairs(frames) do
      local start = system.get_time()
      view.terminal:feed(data)
      sample("feed", system.get_time() - start)
      draw()
    end
    if _ < repeats then
      view:close()
    end
  end
  profiler.stop()
end

---Count calls outside the measured run to avoid instrumenting every cell.
local function report()
  local rect, text = renderer.draw_rect, renderer.draw_text
  local rects, texts = 0, 0

  renderer.draw_rect = function(...)
    rects = rects + 1
    return rect(...)
  end

  renderer.draw_text = function(...)
    texts = texts + 1
    return text(...)
  end

  draw(false)
  renderer.draw_rect, renderer.draw_text = rect, text
  assert(
    renderer.to_canvas(window, 0, 0, width, height):save_image(prefix .. ".png")
  )
  local file = assert(io.open(prefix .. ".timings.txt", "w"))
  local header = string.format(
    "%dx%d cells; %d frames x %d repeats; %d rects/%d texts in final frame\n",
    view.cols,
    view.rows,
    #frames,
    mode == "replay" and repeats or 1,
    rects,
    texts
  )
  file:write(header)
  print(header)
  for _, name in ipairs { "feed", "snapshot", "draw", "present", "frame" } do
    local values = samples[name]
    if values then
      table.sort(values)
      local total = 0
      for _, value in ipairs(values) do
        total = total + value
      end
      local line = string.format(
        "%s: mean %.3f ms, p50 %.3f ms, p95 %.3f ms (%d samples)\n",
        name,
        total / #values,
        values[math.ceil(#values * 0.5)],
        values[math.ceil(#values * 0.95)],
        #values
      )
      file:write(line)
      print(line)
    end
  end
  file:close()
end

local ok, err = xpcall(function()
  assert(mode == "capture" or mode == "replay", "invalid profile mode")
  if mode == "capture" then
    capture()
  else
    replay()
  end
  report()
end, debug.traceback)
profiler.stop()
if trace_file then
  require("jit.v").stop()
end
if view then
  view:close()
end
assert(ok, err)
print("Ghostty profiling complete: " .. prefix)
