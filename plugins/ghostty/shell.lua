-- Keep platform and shell conventions out of the terminal emulation code.
local config = require "plugins.ghostty.config"
local M = {}

---Classify a shell by basename, accepting either platform's path separators.
---@param executable string
---@return "cmd"|"powershell"|"posix"
function M.kind(executable)
  local name = executable:match("([^/\\]+)$"):lower():gsub("%.exe$", "")
  if name == "cmd" then
    return "cmd"
  end
  if name == "powershell" or name == "pwsh" then
    return "powershell"
  end
  return "posix"
end

---Build process arguments with the configured shell's startup/command flags.
---@param options plugins.ghostty.options
---@return string[] argv
function M.argv(options)
  if options.command ~= nil and options.shell ~= true then
    return options.command
  end
  local executable = type(options.shell) == "string" and options.shell
    or config.shell
  local kind = M.kind(executable)
  local argv = { executable }
  local args = options.arguments or config.arguments
  if not args then
    args = kind == "posix" and { "-l" }
      or kind == "cmd" and { "/d" }
      or { "-NoLogo" }
  end
  for _, arg in ipairs(args) do
    argv[#argv + 1] = arg
  end
  if options.shell == true then
    assert(
      type(options.command) == "string",
      "shell=true requires a command string"
    )
    local flags = options.command_arguments
      or config.command_arguments
      or (
        kind == "cmd" and { "/s", "/c" }
        or kind == "powershell" and { "-Command" }
        or { "-c" }
      )
    for _, arg in ipairs(flags) do
      argv[#argv + 1] = arg
    end
    argv[#argv + 1] = options.command
  end
  return argv
end

---Quote a dropped file path for insertion into an interactive shell command.
---@param path string
---@param executable? string
---@return string
function M.quote_path(path, executable)
  local kind = M.kind(executable or config.shell)
  if kind == "cmd" then
    return '"' .. path .. '"'
  end
  if kind == "powershell" then
    return "'" .. path:gsub("'", "''") .. "'"
  end
  return "'" .. path:gsub("'", "'\\''") .. "'"
end

return M
