-- Runs standalone with LuaJIT and through Pragtical's test runner.
local in_editor, test = pcall(require, "core.test")
local source = debug.getinfo(1, "S").source:sub(2)
local root = source:match("^(.*)[/\\]tests[/\\]") or "."
if not in_editor then
  local data = os.getenv("PRAGTICAL_DATA_DIR") or root .. "/../pragtical/data"
  package.path = data .. "/?.lua;" .. package.path
end

---Load defaults without changing the editor's configuration or environment.
---@param platform string
---@param environment table<string, string>
---@param overrides? table
---@return table
local function configure(platform, environment, overrides)
  local config = { plugins = { ghostty = overrides } }
  local chunk = assert(loadfile(root .. "/plugins/ghostty/config.lua"))
  setfenv(chunk, setmetatable({
    PLATFORM = platform,
    os = { getenv = function(name) return environment[name] end },
    require = function(name)
      if name == "core.config" then return config end
      return require(name)
    end,
  }, { __index = _G }))
  return chunk()
end

---@param name string
---@param fn fun()
local function it(name, fn)
  if in_editor then
    test.it(name, fn)
  else
    fn()
    print("ok - " .. name)
  end
end

it("Windows defaults ignore an inherited Unix shell", function()
  local config = configure("Windows", {
    SHELL = "/bin/zsh", COMSPEC = "C:\\Windows\\System32\\cmd.exe",
  })
  assert(config.shell == "C:\\Windows\\System32\\cmd.exe")
  assert(config.config_spec[1].default == config.shell)
end)

it("Windows defaults to cmd when COMSPEC is absent", function()
  assert(configure("Windows", { SHELL = "/bin/zsh" }).shell == "cmd.exe")
end)

it("Unix defaults use SHELL instead of COMSPEC", function()
  for _, platform in ipairs { "Linux", "Mac OS X" } do
    assert(configure(platform, {
      SHELL = "/bin/zsh", COMSPEC = "cmd.exe",
    }).shell == "/bin/zsh")
  end
end)

it("Unix defaults to sh when SHELL is absent", function()
  assert(configure("Linux", {}).shell == "/bin/sh")
end)

it("explicit shell configuration overrides platform defaults", function()
  local config = configure("Windows", { COMSPEC = "cmd.exe" }, {
    shell = "C:\\Tools\\pwsh.exe", arguments = { "-NoProfile" },
  })
  assert(config.shell == "C:\\Tools\\pwsh.exe")
  assert(config.arguments[1] == "-NoProfile")
  assert(config.config_spec[1].default == "cmd.exe")
end)
