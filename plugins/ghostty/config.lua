local config = require "core.config"
local common = require "core.common"

local windows = PLATFORM == "Windows"
local macos = PLATFORM == "Mac OS X"

---@class plugins.ghostty.options
---@field command? string|string[]|false False disables the child process.
---@field shell? string|boolean Use true to interpret command as a shell string.
---@field cwd? string Working directory; views default to the current project.
---@field arguments? string[] Startup flags; an empty table suppresses defaults.
---@field command_arguments? string[] Flags before a shell command string.
---@field environment? table<string, string> Inherited environment overrides.
---@field env? table<string, string> Overrides applied after environment.
---@field title? string Initial tab title, replaced by terminal title events.
---@field close_on_exit? "never"|"clean_exit"|"always"
---@field click_modifier? string Modifier held while left-clicking a link.
---@field cols? integer Initial grid width in cells.
---@field rows? integer Initial grid height in cells.
---@field max_scrollback? integer Maximum number of scrollback lines.
local defaults = {
  shell = os.getenv("SHELL")
    or (windows and (os.getenv("COMSPEC") or "cmd.exe"))
    or "/bin/sh",
  -- nil selects flags for the configured shell; a table overrides them.
  arguments = nil,
  command_arguments = nil,
  environment = {},
  term = "xterm-256color",
  drawer_height = 300,
  max_scrollback = 10000,
  close_on_exit = "clean_exit",
  agent_close_on_exit = "never",
  click_modifier = macos and "cmd" or "ctrl",
  osc52 = "ask",
  osc_max_bytes = 1024 * 1024,
  paste_warning = true,
  -- Follow Pragtical's current FPS; a number overrides the delay in seconds.
  poll_interval = nil,
  read_budget = 256 * 1024,
  write_limit = 4 * 1024 * 1024,
  runtime_path = os.getenv("GHOSTTY_RUNTIME"),
  pty_path = os.getenv("GHOSTTY_PTY_RUNTIME"),
}

defaults.config_spec = {
  name = "Ghostty Terminal",
  {
    label = "Shell",
    description = "Shell executable or path to use for new terminals.",
    path = "shell",
    type = "string",
    default = defaults.shell,
  },
  {
    label = "Terminal Type",
    description = "Value of the TERM environment variable for new terminals.",
    path = "term",
    type = "string",
    default = defaults.term,
  },
  {
    label = "Drawer Height",
    description = "Height of the terminal drawer in pixels.",
    path = "drawer_height",
    type = "number",
    min = 50,
    default = defaults.drawer_height,
  },
  {
    label = "Scrollback Lines",
    description = "Maximum number of scrollback lines kept by new terminals.",
    path = "max_scrollback",
    type = "number",
    min = 0,
    default = defaults.max_scrollback,
  },
  {
    label = "Open Links Modifier",
    description = "Hold this key and left-click to open links or file paths, "
      .. "including line and column references. Applies to new terminals.",
    path = "click_modifier",
    type = "selection",
    default = defaults.click_modifier,
    values = {
      { "Ctrl", "ctrl" },
      { "Shift", "shift" },
      { macos and "Option" or "Alt", macos and "option" or "alt" },
      { macos and "Cmd" or "Super", macos and "cmd" or "super" },
    },
  },
  {
    label = "OSC 52 Clipboard Policy",
    description = "Allow programs in new terminals to write to the clipboard.",
    path = "osc52",
    type = "selection",
    default = defaults.osc52,
    values = {
      { "Ask", "ask" },
      { "Allow", "allow" },
      { "Deny", "deny" },
    },
  },
  {
    label = "Warn Before Unsafe Paste",
    description = "Confirm before pasting potentially unsafe text.",
    path = "paste_warning",
    type = "toggle",
    default = defaults.paste_warning,
  },
  {
    label = "libghostty-vt Path",
    description = "Terminal library override. Leave empty for auto lookup. "
      .. "Requires restart.",
    path = "runtime_path",
    type = "string",
    default = defaults.runtime_path,
  },
  {
    label = "PTY Library Path",
    description = "PTY library override. Leave empty for automatic lookup. "
      .. "Requires restart.",
    path = "pty_path",
    type = "string",
    default = defaults.pty_path,
  },
}

config.plugins.ghostty = common.merge(defaults, config.plugins.ghostty)

return config.plugins.ghostty
