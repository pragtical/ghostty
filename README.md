# Ghostty for Pragtical

Terminal tabs and a bottom drawer for [Pragtical](https://pragtical.dev), with
colors that follow your editor theme. Powered by libghostty-vt through
LuaJIT FFI.

## Installation

Requires Pragtical with LuaJIT and SDL3. Binaries support Linux and macOS on
x86_64/aarch64, and Windows 10 version 1809 or later on x86_64.

Install through Pragtical's plugin manager:

```sh
pragtical pm repo add https://github.com/pragtical/ghostty.git:latest
pragtical pm install ghostty
```

The plugin manager downloads the plugin and its runtime libraries. Restart
Pragtical after installation.

## Using the terminal

| Shortcut | Action |
| --- | --- |
| `Alt+T` | Show or hide the terminal drawer |
| `Shift+Alt+T` | Open or focus the terminal drawer |
| `` Ctrl+Shift+` `` | Open a terminal tab |
| `Ctrl+Shift+C` | Copy the terminal selection |
| `Ctrl+Shift+V` | Paste |
| `Ctrl+Shift+W` | Close the terminal |

On macOS, `Cmd+C` and `Cmd+V` also copy and paste. `Ctrl+C` sends an interrupt
to the terminal program. Editor shortcuts such as `Ctrl+Shift+P` for the command
palette and `Ctrl+Tab` for switching tabs remain available.

New sessions start in the current project directory. Hiding the drawer keeps
its process running. Ordinary terminals close when their shell exits by default;
Spawn Agent views stay open. Both exit policies are configurable in Settings.

- Drag to select text, or double-click to select a word and drag to extend it.
  Hold Shift to select or scroll when a terminal program captures mouse input.
- Use the mouse wheel or drag the right scrollbar to browse scrollback. The
  scrollbar appears when the terminal has saved lines above the visible screen.
- Ctrl-click links or `path:line:column` references to open them; use Cmd-click
  on macOS. Change this under **Ghostty Terminal → Open Links Modifier**.
- Drop files into the terminal to insert their quoted paths.
- Find more actions in the command palette by searching for `ghostty`, including
  clearing the screen, scrolling, and running commands.

**Ghostty: Run Command in Tab** opens a new shell tab and asks for a command.
**Ghostty: Run Command in Drawer** uses the shared drawer, opening it if needed.
Quitting the application returns you to the shell. Use the drawer command while
the drawer is at a shell prompt: it sends input to the current session.

You can also supply the command from your Lua configuration or another plugin:

```lua
local command = require "core.command"
command.perform("ghostty:run-command-in-drawer", "btop")
command.perform("ghostty:run-command-in-tab", "git status")
```

`ghostty:spawn-agent` runs a command as the session's task; it has its own exit
policy and does not return to an interactive shell afterward. On Unix shells,
it loads interactive startup files so commands added to your PATH are available.

If a program crashes or is killed with `Ctrl+\`, it can leave mouse reporting
enabled, making clicks type escape codes at the shell prompt. Open the command
palette with `Ctrl+Shift+P`, run **Ghostty: Reset**, then press Enter for a fresh
prompt. Reset clears the screen and scrollback and restores terminal modes;
the shell keeps running. Use it after returning to the shell.

## Fonts and colors

The terminal uses Pragtical's code font, including its fallback fonts. For
additional symbols commonly used by terminal applications, add these fallbacks
**after your preferred code font** in
**Settings → Core → Editor → Code Font**:

- [JuliaMono Regular](https://github.com/cormullion/juliamono)
- [MesloLGS NF Regular](https://github.com/romkatv/powerlevel10k-media)

The first 16 ANSI colors are generated from your Pragtical theme and update
when you change it. Programs can also use 256 colors and truecolor.

## Configuration

Open **Settings → Plugins → Ghostty Terminal** to change the shell, drawer
height, scrollback, exit behavior, link modifier, and clipboard options. Shell,
exit policy, and link modifier changes apply to new terminals.

**Close on Exit** defaults to **Always**: ordinary tabs and drawers close when
their shell exits, even after a failed command. **Agent Close on Exit** defaults
to **Never**, keeping Spawn Agent output available for inspection. Both settings
also offer **Only on Successful Exit**, which keeps failed sessions visible.

For additional options, edit your Pragtical user configuration:

```lua
local config = require "core.config"

config.plugins.ghostty.close_on_exit = "always"
config.plugins.ghostty.agent_close_on_exit = "never"
config.plugins.ghostty.environment = { MY_VARIABLE = "value" }

-- Optional: poll every 5 ms instead of following the editor's FPS setting.
config.plugins.ghostty.poll_interval = 0.005
```

Polling follows the current FPS setting by default, including Auto FPS. Set
`poll_interval = nil` to restore this behavior after using a fixed interval.

Windows uses `COMSPEC` or `cmd.exe` as the default shell. Linux and macOS use
`SHELL` or `/bin/sh`. You can choose another shell, such as `/bin/zsh` or
`pwsh.exe`, in Settings. Set `arguments` to a list of startup flags, or `{}` to
suppress the defaults.

Clipboard writes requested by terminal programs and potentially unsafe pastes
ask for confirmation by default. The terminal uses `xterm-256color`; choosing
`xterm-ghostty` requires installing Ghostty's terminfo separately.

See the [full reference](AGENTS.md#configuration-usage-and-lua-api)
for appearance overrides, shell options, events, and opening terminals from Lua.

## Building from source

You need **Zig 0.16.0**, a C toolchain with libc headers and `strip`, Python 3,
Meson, and Ninja. On macOS, install the Xcode command-line tools. On Windows,
use an MSYS2 UCRT64 shell.

From this checkout, with Zig on `PATH`:

```sh
meson setup build --buildtype=release
meson compile -C build
python3 scripts/stage-libraries.py build plugins/ghostty
```

Copy `plugins/ghostty`, including both runtime libraries, into Pragtical's user
`plugins` directory and restart the editor. On Linux, the default location is:

```sh
pragtical_userdir="${XDG_CONFIG_HOME:-$HOME/.config}/pragtical"
mkdir -p "$pragtical_userdir/plugins/ghostty"
cp -r plugins/ghostty/. "$pragtical_userdir/plugins/ghostty/"
```

For other platforms, use the user directory shown by Pragtical. The
[build guide](AGENTS.md#building) covers compiler paths, existing builds,
cross-compilation, and packaging.

## License

[MIT](LICENSE). Ghostty's license is included in
[plugins/ghostty/LICENSE.ghostty](plugins/ghostty/LICENSE.ghostty).
