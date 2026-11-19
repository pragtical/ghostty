local ffi = require "ffi"
local runtime = require "plugins.ghostty.runtime"
local config = require "plugins.ghostty.config"
local shell = require "plugins.ghostty.shell"

if ffi.os ~= "Linux" and ffi.os ~= "OSX" and ffi.os ~= "Windows" then
  error("Ghostty's PTY transport supports Linux, macOS and Windows")
end

ffi.cdef [[
typedef struct PgtPty PgtPty;
int pgt_pty_abi(void);
PgtPty *pgt_pty_new(const char *const *argv, const char *const *env,
                  const char *cwd, unsigned short cols, unsigned short rows,
                  char *error, size_t error_len);
long pgt_pty_read(PgtPty *, void *, size_t);
long pgt_pty_write(PgtPty *, const void *, size_t);
int pgt_pty_resize(PgtPty *, unsigned short, unsigned short,
                   unsigned short, unsigned short);
int pgt_pty_poll(PgtPty *, int *, int *);
int pgt_pty_pid(PgtPty *);
void pgt_pty_close(PgtPty *);
void pgt_pty_reap(void);
]]

local C, path = runtime.load(
  "ghostty-pty",
  config.pty_path,
  { "pgt_pty_abi", "pgt_pty_reap" }
)
assert(C.pgt_pty_abi() == 1, "Unsupported Ghostty PTY ABI")
local M = { C = C, path = path }

if ffi.os ~= "Windows" then ffi.cdef "int kill(int pid, int sig);" end

---Release a PTY. Forced closes kill the foreground task group before reaping.
---@param handle ffi.cdata Owned PTY handle
---@param force boolean?
function M.close(handle, force)
  -- ConPTY closes the child job in its native waiter.
  if force and ffi.os ~= "Windows" then
    ffi.C.kill(-C.pgt_pty_pid(handle), 9)
  end
  C.pgt_pty_close(ffi.gc(handle, nil))
end

---Keep the Lua strings alive while C uses the returned pointers.
---@param values string[]
---@return ffi.cdata Null-terminated argv-style pointer array.
local function strings(values)
  local array = ffi.new("const char *[?]", #values + 1)
  for i, value in ipairs(values) do
    assert(
      type(value) == "string" and not value:find("%z"),
      "Invalid process argument"
    )
    array[i - 1] = value
  end
  return array
end

---Start a PTY child with validated arguments and environment overrides.
---@param options plugins.ghostty.options
---@param defaults? plugins.ghostty.options Settings inherited from the view.
---@return ffi.cdata? handle Owned handle with a close finalizer.
---@return string? error
function M.new(options, defaults)
  defaults = defaults or config
  local argv = shell.argv(options)
  assert(
    type(argv) == "table" and #argv > 0,
    "command must be a nonempty argument array"
  )
  assert(
    not options.cwd or not options.cwd:find("%z"),
    "Invalid working directory"
  )
  local env = {}
  local overrides = { TERM = options.term or defaults.term or config.term, COLORTERM = "truecolor" }
  local function overlay(values)
    for key, value in pairs(values or {}) do
      assert(
        type(key) == "string" and key ~= "" and not key:find("[=%z]"),
        "Invalid environment key"
      )
      value = tostring(value)
      assert(not value:find("%z"), "Invalid environment value")
      overrides[ffi.os == "Windows" and key:upper() or key] = value
    end
  end
  overlay(defaults.environment)
  overlay(defaults.env)
  overlay(options.environment)
  overlay(options.env)
  for key, value in pairs(overrides) do env[#env + 1] = key .. "=" .. value end
  local args, vars = strings(argv), strings(env)
  local error = ffi.new("char[512]")
  local handle = C.pgt_pty_new(
    args,
    vars,
    options.cwd,
    options.cols,
    options.rows,
    error,
    512
  )
  -- Keep the strings (not just their C pointers) live until spawn has returned.
  assert(argv and env)
  if handle == nil then
    error = ffi.string(error)
    return nil, error
  end
  return ffi.gc(handle, C.pgt_pty_close)
end

-- Keep argv/env strings live across the synchronous C spawn.
jit.off(M.new, true)

return M
