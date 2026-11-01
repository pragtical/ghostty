-- Run inside Pragtical to use its bundled jit.p and the actual renderer.
-- See AGENTS.md for capture/replay commands and environment options.
local source = debug.getinfo(1, "S").source:sub(2)
local root = source:match("^(.*)[/\\]scripts[/\\]") or "."
root = os.getenv("GHOSTTY_PROFILE_PLUGIN") or root
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
local mode = os.getenv("GHOSTTY_PROFILE_MODE") or "capture"
local prefix = os.getenv("GHOSTTY_PROFILE_OUTPUT") or "/tmp/ghostty-profile"
local count_calls = os.getenv("GHOSTTY_PROFILE_CALLS") == "1"
local native_calls = {}
if count_calls then
  local runtime = require "plugins.ghostty.runtime"
  local native = runtime.C
  runtime.C = setmetatable({}, {

    ---@param proxy table
    ---@param key string Native symbol or enum name.
    __index = function(proxy, key)
      local value = native[key]
      if key:match("^ghostty_") then
        local call = value

        value = function(...)
          native_calls[key] = (native_calls[key] or 0) + 1
          return call(...)
        end
      end
      rawset(proxy, key, value)
      return value
    end,
  })
end
local ghostty = require "plugins.ghostty"
local recording = os.getenv("GHOSTTY_PROFILE_INPUT") or prefix .. ".frames"
local repeats = tonumber(os.getenv("GHOSTTY_PROFILE_REPEATS")) or 10
assert(repeats >= 1 and repeats % 1 == 0, "repeats must be a positive integer")
local width, height = 1600, 900
local frames, samples = {}, {}
local sessions = {}
local iterations, retained_before, retained_after
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
  sessions[view] = true
end

---Close a benchmark session without retaining it during later repeats.
---@param terminal_view plugins.ghostty.TerminalView
local function close_view(terminal_view)
  terminal_view:close()
  sessions[terminal_view] = nil
end

---Collect stable memory and VM-state samples after warming the workload.
local function start_profile()
  samples, native_calls = {}, {}
  collectgarbage("collect")
  retained_before = collectgarbage("count")
  if not count_calls then
    profiler.start(
      os.getenv("GHOSTTY_PROFILE_FORMAT") or "vf3i1m1",
      prefix .. ".jit.txt"
    )
  end
end

---Stop sampling before collecting retained Lua memory, including samples.
local function stop_profile()
  profiler.stop()
  collectgarbage("collect")
  retained_after = collectgarbage("count")
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
  close_view(view)
  start_profile()
  for _ = 1, repeats do
    create_view(false)
    for _, data in ipairs(frames) do
      local start = system.get_time()
      view.terminal:feed(data)
      sample("feed", system.get_time() - start)
      draw()
    end
    if _ < repeats then
      close_view(view)
    end
  end
  stop_profile()
end

---Exercise deterministic output and idle sessions independently of btop.
local function exercise()
  local workload = os.getenv("GHOSTTY_PROFILE_WORKLOAD") or "redraw"
  local idle = workload == "idle" or workload == "sessions"
  iterations = tonumber(os.getenv("GHOSTTY_PROFILE_ITERATIONS"))
    or (idle and 100000 or 1000)
  assert(iterations >= 1 and iterations % 1 == 0, "invalid iteration count")
  create_view(false)
  local lines = {}
  for i = 1, view.rows do
    lines[i] = string.rep("abc123 ", math.floor(view.cols / 7))
  end
  local repaint = "\27[H" .. table.concat(lines, "\r\n")
  local live = {}
  if workload == "sessions" then
    for _ = 1, 6 do
      create_view(PLATFORM == "Windows" and { "cmd.exe", "/d", "/q" }
        or { "/bin/sh", "-i" })
      live[#live + 1] = view
    end
    -- Allow startup output to arrive before measuring empty polls.
    for _ = 1, 20 do
      for _, terminal_view in ipairs(live) do terminal_view:poll() end
      system.sleep(0.005)
    end
  elseif workload == "scroll" then
    for i = 1, 1000 do
      view.terminal:feed(string.format("history line %04d\r\n", i))
    end
  else
    assert(idle or workload == "redraw" or workload == "stream"
      or workload == "unicode", "invalid workload")
  end

  ---@param i integer Deterministic workload step.
  ---@param measure boolean Whether to retain timing samples.
  local function step(i, measure)
    local start = system.get_time()
    if workload == "idle" then
      view:update()
      if measure then sample("update", system.get_time() - start) end
    elseif workload == "sessions" then
      for _, terminal_view in ipairs(live) do terminal_view:poll() end
      if measure then sample("poll", system.get_time() - start) end
    else
      if workload == "redraw" then
        view.terminal:feed(repaint)
      elseif workload == "stream" then
        view.terminal:feed(string.rep(
          "build line " .. i .. " complete\r\n", 32
        ))
      elseif workload == "unicode" then
        view.terminal:feed("\27[H" .. string.rep(
          "\27[38;2;12;34;56m界é🙂\27[0m " .. i .. "\r\n", view.rows
        ))
      else
        view.terminal:scroll_to((i % 100) * 7)
      end
      if measure then sample("feed", system.get_time() - start) end
      draw(measure)
    end
  end

  for i = 1, 100 do step(i, false) end
  start_profile()
  for i = 1, iterations do step(i, true) end
  stop_profile()
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

  local ok, err = pcall(draw, false)
  renderer.draw_rect, renderer.draw_text = rect, text
  assert(ok, err)
  assert(
    renderer.to_canvas(window, 0, 0, width, height):save_image(prefix .. ".png")
  )
  local file = assert(io.open(prefix .. ".timings.txt", "w"))
  local header = string.format(
    "%dx%d cells; %d frames x %d repeats; %d rects/%d texts in final frame\n",
    view.cols,
    view.rows,
    iterations or #frames,
    mode == "replay" and repeats or 1,
    rects,
    texts
  )
  file:write(header)
  print(header)
  local phases = { "feed", "snapshot", "draw", "present", "frame",
    "update", "poll" }
  for _, name in ipairs(phases) do
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
  if retained_before then
    local memory = string.format(
      "Lua memory after collection: %.1f -> %.1f KiB (includes samples)\n",
      retained_before, retained_after
    )
    file:write(memory)
    print(memory)
  end
  if count_calls then
    file:write("Instrumented run: timings are not comparable.\n")
    local names = {}
    for name in pairs(native_calls) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
      file:write(string.format("%s: %d calls\n", name, native_calls[name]))
    end
  end
  file:close()
end

local ok, err = xpcall(function()
  assert(mode == "capture" or mode == "replay" or mode == "exercise",
    "invalid profile mode")
  if mode == "capture" then
    capture()
  elseif mode == "exercise" then
    exercise()
  else
    replay()
  end
  report()
end, debug.traceback)
profiler.stop()
if trace_file then
  require("jit.v").off()
end
for terminal_view in pairs(sessions) do
  local closed, message = pcall(terminal_view.close, terminal_view)
  if ok and not closed then ok, err = false, message end
end
assert(ok, err)
print("Ghostty profiling complete: " .. prefix)
