# Ghostty for Pragtical: project guide

This file records the architecture, development workflow, and testing procedures.
Run commands from the project root unless a section says otherwise. Keep this
guide and `README.md` current when build, runtime, or release behavior changes.
Keep README.md focused on installation, everyday use, common settings, and a
short source-build example. Put architecture, detailed build instructions,
testing, profiling, release procedures, and contributor guidance in this file.
Use repository-relative paths, environment variables, or `/path/to/...`
placeholders in project files. Keep contributor usernames, home directories,
machine names, installed tool locations, and private workspace details out of them.

## Purpose and current status

The plugin provides terminal tabs and a bottom drawer in Pragtical. LuaJIT FFI
calls **libghostty-vt directly** for VT emulation, screen state, scrollback, input
encoding, and formatting. Pragtical's renderer draws the terminal cells.

Each installation needs the Lua plugin and two ordinary shared libraries:

- `ghostty-vt`: the pinned upstream Ghostty VT library.
- `ghostty-pty`: this project's small process and pseudo-terminal transport.

The VT API does not launch shells or supply the OS process transport. That is why
the PTY library is necessary. It has no Lua or Ghostty dependency; the Lua layer
connects the two libraries. There is no Lua C module or C wrapper around Ghostty.

Runtime requirements are Pragtical with LuaJIT and the current SDL3 renderer
APIs. Supported platforms are Linux, macOS, and Windows 10 version 1809 or later
(ConPTY). The release matrix covers Linux and macOS on x86_64 and aarch64, and
Windows on x86_64.

The upstream plugin repository is `pragtical/ghostty` on GitHub. Check the
checkout's Git status and current GitHub Actions results before release work.
Plugin-manager `latest` URLs require a successful versioned release.

## Source map

| Path | Responsibility |
| --- | --- |
| `plugins/ghostty/init.lua` | TerminalView, tabs/drawer, commands, key routing, polling, drawing, clipboard prompts, and editor lifecycle |
| `plugins/ghostty/config.lua` | Defaults and Pragtical configuration UI metadata |
| `plugins/ghostty/palette.lua` | Theme-derived 16-color ANSI palette, contrast adjustment, and change signatures |
| `plugins/ghostty/shell.lua` | Shell classification, startup/command arguments, and dropped-file quoting |
| `plugins/ghostty/runtime.lua` | Library discovery, symbol checks, and Ghostty ABI layout checks |
| `plugins/ghostty/ffi_defs.lua` | Generated declarations from the pinned Ghostty headers |
| `plugins/ghostty/terminal.lua` | Direct Ghostty FFI backend, render snapshots, input encoding, PTY polling, write queue, and events |
| `plugins/ghostty/pty.lua` | Transport FFI declarations, argument/environment validation, and handle ownership |
| `plugins/ghostty/osc.lua` | Bounded OSC observer for working directories, clipboard writes, and notifications |
| `plugins/ghostty/events.lua` | Event subscriptions and listener error isolation |
| `plugins/ghostty/selection.lua` | Selection within the visible viewport |
| `plugins/ghostty/click_to_open.lua` | URLs, file URLs, path:line:column links, and Windows path handling |
| `src/pty.c` | POSIX forkpty transport and asynchronous child reaping |
| `src/pty_windows.c` | Windows ConPTY transport, overlapped I/O, and process cleanup |
| `meson.build`, `meson_options.txt` | Main build configuration and installation |
| `subprojects/ghostty.wrap` | Pinned upstream source archive and checksum |
| `subprojects/packagefiles/ghostty/` | Authoritative Meson overlay and Zig build helper |
| `resources/cross/linux-mingw32-x86_64.ini` | Linux-to-Windows MinGW toolchain with Wine test wrapper |
| `scripts/generate-ffi.py` | Regenerate portable LuaJIT declarations from upstream C headers |
| `scripts/stage-libraries.py` | Find the two runtime targets through Meson introspection and copy them |
| `scripts/check-release.py` | Validate manifest/platform assets and optionally write SHA256SUMS |
| `scripts/preview.lua` | Render a sample terminal to a PNG |
| `scripts/profile.lua` | Capture btop and replay its frames with Pragtical's bundled jit.p |
| `scripts/test-windows.lua` | Run the Lua suites in Windows Pragtical, including under Wine |
| `tests/abi.c` | C sizes and offsets used to check the FFI declarations |
| `tests/pty.c`, `tests/pty_windows.c` | Native transport integration tests |
| `tests/backend.lua`, `tests/view.lua` | FFI backend and Pragtical UI integration tests |
| `.github/workflows/build.yml`, `manifest.json` | Build/release workflow and plugin-manager installation metadata |

## Runtime rules that matter when making changes

### Code style and documentation

- Keep source lines at most 80 characters, including comments. Use two spaces
  for Lua/C indentation and four for Python.
- Leave a blank line between function or method definitions, including local
  helpers and callbacks. Keep declarations separate from adjacent statements.
- Document every local Lua helper's parameter types with `---@param`. Add
  purpose, return types, units, ownership, or coordinate conventions where they
  help a caller. Document public terminal/view APIs with LuaDoc comments.
- `stylua.toml` and `.clang-format` record the formatter settings. StyLua ignores
  generated FFI declarations; regenerate them with `scripts/generate-ffi.py`,
  which wraps declarations at whitespace without changing C tokens.
  Keep the generated `local ffi = require "ffi"` and `ffi.cdef [[` form:
  Pragtical's Lua syntax uses that call to highlight the block as C.
- Formatting tools are optional development tools, not build dependencies:

  ```sh
  stylua --verify --respect-ignores plugins/ghostty scripts/*.lua tests/*.lua
  clang-format -i src/*.c tests/*.c
  black --line-length 80 scripts/*.py \
    subprojects/packagefiles/ghostty/build-vt.py
  ```

### Reusing Pragtical and Ghostty APIs

- Use `core.common` for clamping, rounding, interpolation, merging tables, and
  expanding `~`, and `core.json` to decode Ghostty's ABI metadata. Read the
  current project path through `core.root_project()`.
- Read rendered cell text with Ghostty's `GRAPHEMES_UTF8` query. Keep the Lua
  buffer owner alive while C writes to its pointer, and grow the buffer on
  `GHOSTTY_OUT_OF_SPACE`. Selection text comes from Ghostty's formatter.
- Double-click word bounds come from `ghostty_terminal_select_word` using
  Ghostty's default boundaries, which keep underscores and paths together.
  Convert grid references immediately to viewport cells and clip wrapped words
  at the viewport edges. Keep the initial word selected while dragging in either
  direction, and keep selection active until release so Shift-selection never
  sends part of its gesture to the terminal application.
- Fetch raw cells once per row with `CELLS_RAW`; the borrowed pointer must not
  survive a render-state update. Batch style/text with `row_cells_get_multi`.
  Keep optional foreground/background queries separate: an absent color stops
  a batch with `INVALID_VALUE`. Preserve all owners of its output pointers.
- Treat render snapshots as immutable. Reuse unchanged cells even in dirty rows,
  since TUIs often rewrite identical content. Colors use a weak-value cache so
  transient application truecolors can be collected. Drawing caches use row
  identity; changing text, style, colors or dimensions must invalidate reuse.
- Combine background rectangles and skip blank glyphs, including redundant
  default-background fills. Keep decorations on spaces and draw selection after
  backgrounds. Position glyphs by terminal cells; concatenating arbitrary text
  can break alignment with fractional font advances or fallback fonts.
- Reuse View's `v_scrollbar` widget for drawing, hover, track clicks, and dragging.
  Ghostty's `GHOSTTY_TERMINAL_DATA_SCROLLBAR` supplies `total`, `offset`, and `len`
  in rows. History height is `(total - len) * cell_height`; add the view height
  for the widget's scrollable size. Its position is `offset / (total - len)`,
  with a zero-range guard. Keep View's pixel scrolling disabled: Ghostty owns
  the viewport, and gestures use `GHOSTTY_SCROLL_VIEWPORT_ROW` absolute offsets.
  Overlay the scrollbar so history growth does not resize terminal columns.
  Hide it without history, including on the alternate screen. Consume the whole
  scrollbar gesture, including release if the history disappears during a drag,
  before sending mouse events to the application or starting text selection.
- Keep the HSL/contrast palette algorithm; core's color converters use HSV.
  Preserve Windows paths, file-URL decoding, and shell-specific argument quoting.
  URL opening uses argument arrays or `ShellExecuteW`, so shell interpolation
  cannot interpret terminal-provided URLs.

### FFI ownership and callbacks

- Keep Ghostty calls and callbacks on the editor thread. Windows cleanup workers
  must never call Lua or Ghostty.
- Callback cdata is shared across terminals to avoid exhausting LuaJIT callback
  slots. A weak instance registry and numeric userdata identify each terminal.
- Preserve the `jit.off` calls on `Terminal.feed`, `Terminal.resize`, and PTY
  spawning. Ghostty can call back into Lua during feed/resize; spawning must keep
  Lua strings alive while C reads their pointers.
- Preserve the owners of memory borrowed by C. In particular, `self.key_text`
  retains key-event text, `self.selection_buffer` retains formatter selection
  data, and the argv/environment strings must survive the complete spawn call.
- Native objects use `ffi.gc` and explicit close paths. Lua close operations
  should remain idempotent and must not leave a finalizer owning a freed object.
- `runtime.lua` checks required symbols and the sizes, alignments, and offsets
  exported by `ghostty_type_json()`. It requires schema version 1 and at least
  ten recognized struct/union layouts, including nested field descriptors.
  This cannot detect all enum or semantic changes, so keep the upstream pin.

### Polling, rendering, and input

- Partial writes stay queued. Preserve the per-poll byte budget and total queued
  input limit so a busy terminal does not monopolize an editor frame.
- Hidden terminals keep polling. Continue POSIX reaping after the last view is
  closed, and drain final output before notifying the user of process exit.
- With `poll_interval = nil`, calculate `1 / config.fps` on each polling pass.
  Core and Settings keep this value in sync with Auto FPS and display changes.
  An explicit numeric interval overrides FPS. Clamp the delay to at least
  1 ms, allowing the Settings UI's full 10–300 FPS range. Use the configured
  target rather than `core.fps`, which can drop when rendering is overloaded.
  Fall back to 60 FPS when the target is zero or negative: SDL's dummy display
  can report zero, which otherwise leaves the polling coroutine asleep forever.
- Closing a terminal must remove its actual view/tab node. With `clean_exit`,
  only exit code zero with no signal closes automatically; failures stay visible.
- Let SDL text input supply printable repeats. Synthesizing another printable
  key repeat duplicates input.
- Create terminals with `ghostty_terminal_new(allocator, out, cols, rows)` and
  set `GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES` separately using a `size_t*`.
  Query modes through `GHOSTTY_TERMINAL_DATA_MODE` with a
  `GhosttyTerminalModeConfig`, and render colors through
  `GHOSTTY_RENDER_STATE_DATA_COLORS`. The old constructor options struct and
  dedicated mode/color getters were removed upstream.
- When SDL text input changes a shifted printable key (such as `;` to `:`), mark
  Shift in `event.consumed_mods` and pass that mask to Ghostty. Otherwise Kitty
  keyboard mode sends a modified base key instead of text, breaking Neovim's `:`
  command. Preserve modifiers for unchanged text such as Shift+Space and for
  shortcuts; keep using the encoder for applications requesting full key events.
- Use Ghostty's key, mouse, focus, and paste encoders. They implement application
  cursor modes, Kitty keyboard events, bracketed paste, and other terminal modes.
  Enter uses the encoder on Windows too.
- `ghostty:reset` recovers from programs killed before restoring terminal modes.
  Feed CAN followed by RIS to cancel incomplete control strings in both parsers
  and reset Ghostty. Clear cached snapshots, mouse encoder state, selection, and
  held input state; keep the PTY alive. Reset clears the screen and scrollback.
  Do not reset automatically on Ctrl+\\: programs may handle or ignore SIGQUIT,
  and the shell's lifetime does not tell us when a foreground job has exited.
- Set the mouse encoder's `ANY_BUTTON_PRESSED` option for held physical buttons.
  Ghostty otherwise drops drags beyond the cell grid, including the partial-cell
  margin beside the scrollbar at some font sizes. Clear it for releases, passive
  motion, and wheel events; wheel directions are not held buttons.
- Pragtical names the Space key `space`; supply unshifted codepoint 32 to the
  Ghostty key event. Without it, Kitty release reporting falls back to plain
  text and inserts another space on key-up (visible in Codex). Keep tests for
  Space presses, repeats, releases, and Shift/Ctrl modifiers in both Lua suites.
- Rendering follows `style.code_font`, including fallback fonts. Bold/italic font
  copies need an explicit size. Missing CJK or symbol glyphs can require user font
  configuration even when the terminal cell data is correct.
- The pinned VT API needs the OSC 7 observer to maintain the working directory.
  The observer handles chunk boundaries, ignores embedded DCS/APC strings, and
  bounds message sizes. Preserve these properties when changing OSC handling.
- OSC 52 clipboard writes ask by default; reads are ignored. Unsafe paste prompts
  and Ghostty paste encoding are part of the existing behavior.

### PTY ABI and platform behavior

Both implementations expose ABI version 1 through `pgt_pty_abi()`, with the same
`pgt_pty_new/read/write/resize/poll/pid/close/reap` interface declared in `pty.lua`.
Read/write return `-2` for would-block, `-1` for error, and read returns zero for
EOF. Keep the C implementations and FFI declarations in sync; change the ABI
version if the contract becomes incompatible.

**POSIX (`src/pty.c`):**

- Uses `forkpty`; the master is nonblocking and close-on-exec. Linux needs
  `libutil` and `<pty.h>`; macOS uses `<util.h>`.
- Prepare the environment and executable before forking. The child stays in C
  through signal reset, descriptor cleanup, working-directory change, and
  `execve`; it must never return into Lua in the multithreaded editor.
- A close-on-exec error pipe reports spawn failures synchronously. Linux PTY
  `EIO` on read is treated as EOF. Resize uses `TIOCSWINSZ`.
- Poll uses `waitpid(..., WNOHANG)`. Close sends SIGHUP to the process group and
  queues reaping; after roughly 0.2 seconds it escalates to SIGTERM and after
  0.7 seconds to SIGKILL. A library destructor finishes pending cleanup.
- Keep this cleanup driven by polling rather than a POSIX worker thread: code
  must not remain active in an unloaded library during editor restart.

**Windows (`src/pty_windows.c`):**

- Dynamically resolves ConPTY entry points and reports an error when unavailable.
- Converts UTF-8 arguments, environment, and cwd to UTF-16. The inherited
  environment preserves hidden drive entries such as `=C:`, applies overrides
  case-insensitively, and supplies a sorted Unicode environment block.
- Resolves executables using the child's PATH/cwd. Ordinary arguments use Windows
  CRT quoting; `cmd /s /c` command strings need their separate quoting path.
- Creates the process suspended, assigns it to a kill-on-close job, then resumes
  it. This allows cleanup of descendants as well as the initial shell.
- Sets `STARTF_USESTDHANDLES` with null child standard handles so ConPTY supplies
  them. Without this flag, Windows can copy the host's redirected streams even
  with `bInheritHandles=FALSE`, sending shell output into the host's log instead
  of the terminal. Preserve the host's own handles; do not clear them globally.
  See [Microsoft's ConPTY discussion](https://github.com/microsoft/terminal/discussions/15814).
- Uses named byte pipes with overlapped host ends and synchronous ConPTY ends.
  Pending I/O owns C buffers of 64 KiB, so FFI buffers can disappear safely after
  a call returns. Windows `long` is 32-bit; transfers stay bounded.
- A native waiter observes process exit or shutdown, terminates job descendants,
  and closes ConPTY while the editor drains output. `ClosePseudoConsole` can
  block waiting for output on older Windows versions; keep it off the UI thread.
- Shared state is reference-counted, and an SRW lock protects resize versus close.
  The waiter holds a DLL reference and releases it with `FreeLibraryAndExitThread`
  so a restart cannot unload code that the worker is still executing.
- Close cancels I/O and closes pipes before signaling the waiter. Poll waits for
  process completion and drained output/EOF before reporting exit.
  `pgt_pty_reap()` is a no-op because the waiter handles cleanup.

## Building

### Dependencies and upstream pin

Source builds require a C compiler, its target-compatible `strip` tool,
libc development headers, Python 3,
Meson >= 0.60, Ninja, and **exactly Zig 0.16.0**. macOS needs Xcode command-line
tools. Native Windows builds use an MSYS2 UCRT64 shell with GCC, Python, Meson,
Ninja, and Zig on PATH. Installing standalone LuaJIT enables the Meson FFI test;
that test also needs Pragtical's Lua core modules (see Testing below).

Ghostty is a **Meson wrap subproject**. Keep this
arrangement; upstream source does not belong in a vendor directory.

- Commit: `12752b2ac1bb05ce53402ed8c853ed1f96eef0b1`.
- Archive SHA-256:
  `4a5d516c161b5543204dd9ce923b841b049ad9d46614b6bd28ee714148d085ac`.
- The overlay identifies the VT library as `0.1.0-dev`. Upstream's application
  version remains `1.3.2-dev`; the library has its own version. This plugin's
  version is `0.2.0` in both `meson.build` and `manifest.json`.
- `subprojects/packagefiles/ghostty/build-vt.py` checks the Zig version and runs
  `zig build` with `-Demit-lib-vt=true`, `-Demit-xcframework=false`,
  `-Doptimize=ReleaseFast`, `-Dtarget=...`, and `-Dcpu=baseline`.
  Disabling the default Apple XCFramework build limits the output to the host's
  shared library.
- The helper passes `-Dversion-string=1.3.2-dev` to disable upstream's Git
  version lookup. The downloaded source has no Git metadata; without this
  override, it discovers the plugin's enclosing repository and rejects tags
  such as `v0.1.0` on every platform. Keep this application version in sync with
  upstream's `build.zig.zon` when changing the pin. The VT library retains its
  separate upstream version. Verify build changes from a tagged checkout.
- Linux/macOS use the native Zig target. Windows uses the host CPU with
  `-windows-gnu`, including in native Windows builds. Cross compilation currently
  supports Windows targets only; ARM Linux/macOS CI uses native runners.
- Keep the explicit baseline CPU option for portable releases. A native target
  otherwise enables the CI runner's CPU features: the first Linux release
  emitted AVX-512 instructions in terminal creation and crashed with `SIGILL`
  on an AVX2-only CPU. Passing tests on the build runner does not prove CPU
  portability. The Linux x86_64 CI job runs the VT backend tests against the
  stripped package under `qemu-x86_64 -cpu Nehalem`, which exposes no AVX.
  Validate downloaded releases on a less capable CPU as well.
- The build helper removes debug information from the runtime VT library with
  the toolchain's `strip -S`, preserving FFI exports and removing embedded build
  paths. With Meson's `-Dstrip=true`, it also strips unneeded symbols using
  `strip` on Linux/Windows or `strip -S -x` on macOS. Meson does not automatically
  strip custom targets, so the helper reads the same built-in option. Meson
  selects the MinGW strip tool from the Windows cross file.

### Native build and staging

Configure a release build in `build`, compile it, and stage both libraries
beside the Lua files:

```sh
meson setup build --buildtype=release -Dzig=/path/to/zig-0.16.0/zig
meson compile -C build
python3 scripts/stage-libraries.py build plugins/ghostty
```

Omit `-Dzig=` if Zig 0.16.0 is already on `PATH`. For an existing build, compile
and stage again after changes. To change options, use
`meson setup --reconfigure build ...`. Setting `-Darch_tuple=` changes filenames,
not the compiler target.

When upgrading an existing build that cached the subproject's Zig path, also set
`-Dghostty:zig=/path/to/zig-0.16.0/zig` during reconfiguration. Fresh builds inherit
the root project's `-Dzig=` option.

For example, when upgrading a build configured with Zig 0.15.2:

```sh
meson setup --reconfigure build -Dzig=/path/to/zig-0.16.0/zig \
  -Dghostty:zig=/path/to/zig-0.16.0/zig
```

Expected names are `ghostty-vt.<arch>.<suffix>` and
`ghostty-pty.<arch>.<suffix>`. Valid release architectures are:

| Architecture | Suffix |
| --- | --- |
| `x86_64-linux`, `aarch64-linux` | `.so` |
| `x86_64-darwin`, `aarch64-darwin` | `.so` |
| `x86_64-windows` | `.dll` |

The macOS files are Mach-O shared libraries deliberately named `.so`, following
Pragtical's plugin naming convention. Preserve that naming in the loader,
manifest, build, and CI. The staging script uses Meson target paths; use it
instead of guessing paths inside the extracted subproject.

To stage a complete plugin in a separate package directory:

```sh
meson setup build-package --buildtype=release -Dstrip=true \
  -Dzig=/path/to/zig-0.16.0/zig -Ddata_dir=/
meson compile -C build-package
meson install -C build-package --no-rebuild --destdir "$PWD/package"
```

This produces `package/plugins/ghostty`. The default `data_dir` is
`share/pragtical`; without the override, installation uses the configured prefix
and that data directory inside the staging root.
The strip option takes effect during installation for the PTY library and
during the custom build for VT. `scripts/stage-libraries.py` copies build
outputs, so use `meson install` when packaging stripped libraries. Add
`--tags runtime` to install only the two shared libraries.

### Subproject changes, offline builds, and declarations

Meson downloads and verifies the archive from `subprojects/ghostty.wrap`, then
applies `subprojects/packagefiles/ghostty`. The extracted
`subprojects/ghostty-<revision>` directory is generated and ignored. Make lasting
overlay changes in `packagefiles`; ensure the extracted copy receives them before
testing an already configured build. Editing only the extracted tree loses work.

For offline setup, put the archive named by the wrap's `source_filename` in
`subprojects/packagecache/`. Zig dependencies must also be cached in the build
directory's `zig-cache`. Build outputs, Zig caches, and install prefixes stay
under the build tree.

After configuring Meson, regenerate declarations with:

```sh
python3 scripts/generate-ffi.py
```

The script reads the wrap to find headers; it also accepts an upstream source
directory argument. It uses `cc` as a C preprocessor, supplies minimal standard
headers to avoid embedding host libc definitions, removes inline helpers, and
normalizes GCC/Clang whitespace and fixed-underlying-type enum syntax for LuaJIT.
The enum sentinels retain C `int` size. Do not edit `ffi_defs.lua` by hand. When
updating Ghostty, update the wrap/checksum, the generator's revision comment,
any required Zig version references, regenerate declarations, and run ABI and
runtime tests.
CI checks that regeneration produces no diff on Linux/macOS.

### Cross-compiling Windows on Linux

Install MinGW x86_64 tools and Wine. Use this project's cross file: Pragtical's
own file contains project options that this project's Meson build does not accept.

```sh
export WINEPREFIX="${TMPDIR:-/tmp}/ghostty-wine"
mkdir -p "$WINEPREFIX"
export WINEDEBUG=-all
export WINEDLLOVERRIDES=mscoree,mshtml=d
meson setup build-windows --buildtype=release \
  --cross-file resources/cross/linux-mingw32-x86_64.ini \
  -Dzig=/path/to/zig-0.16.0/zig
meson compile -C build-windows
meson test -C build-windows --no-rebuild --print-errorlogs
python3 scripts/stage-libraries.py build-windows plugins/ghostty
```

The Wine prefix directory must exist before Meson checks the executable wrapper.
The Windows DLL pair can coexist with Linux libraries in the source plugin
directory. Cross builds skip the host LuaJIT Meson test because a Linux LuaJIT
cannot load Windows DLLs; run the Windows editor harness separately.

## Installation and library discovery

A copied plugin installation must be refreshed after source changes and staging.
For the default Linux user directory:

```sh
pragtical_userdir="${XDG_CONFIG_HOME:-$HOME/.config}/pragtical"
mkdir -p "$pragtical_userdir/plugins/ghostty"
cp -r plugins/ghostty/. "$pragtical_userdir/plugins/ghostty/"
```

Restart Pragtical after replacing native libraries. Keep both runtime libraries
beside the Lua files. On other platforms, use the user directory reported by
Pragtical. A development symlink is also possible, but check the existing copy
before replacing it. For a fresh installation, run this from the checkout:

```sh
pragtical_userdir="${XDG_CONFIG_HOME:-$HOME/.config}/pragtical"
mkdir -p "$pragtical_userdir/plugins"
ln -s "$PWD/plugins/ghostty" "$pragtical_userdir/plugins/ghostty"
```

Adding or changing project documentation does not require reinstalling Lua.

Library overrides are `config.plugins.ghostty.runtime_path` / `GHOSTTY_RUNTIME`
and `pty_path` / `GHOSTTY_PTY_RUNTIME`. An explicit path is used exclusively;
without one, the loader tries architecture-qualified and generic bundled names,
then the system library search path. It prefers Pragtical's `ARCH`, with a
fallback mapping from LuaJIT CPU/OS names (`x64` to `x86_64`, `arm64` to `aarch64`,
`OSX` to `darwin`). Layout mismatches should fail with a useful error.

Once the first versioned release exists, plugin-manager installation is:

```sh
pragtical pm repo add https://github.com/pragtical/ghostty.git:latest
pragtical pm install ghostty
```

The manager copies the Lua plugin and downloads both libraries for its platform;
users installing these binaries do not need a compiler or Zig. No entry has been
added to the separate central plugin index in the `pragtical/plugins` repository.

## Testing and debugging

### Native Linux and Pragtical integration

After a code change, rebuild and stage before running tests against the source
plugin directory:

```sh
meson compile -C build
python3 scripts/stage-libraries.py build plugins/ghostty
meson test -C build --no-rebuild --print-errorlogs
SDL_VIDEO_DRIVER=dummy PRAGTICAL_USERDIR="${TMPDIR:-/tmp}/ghostty-test-user" \
  pragtical test tests
```

The SDL3 variable is `SDL_VIDEO_DRIVER`. The Lua suites add the workspace to
`package.path`; avoid confusing results from a previously loaded installed copy.
`tests/backend.lua` also runs with `luajit tests/backend.lua`, supplying its own
configuration stub. Standalone tests load the real `core.common` and `core.json`
from `../pragtical/data` by default. For another checkout or installation, set
`PRAGTICAL_DATA_DIR=/path/to/pragtical/data` when running LuaJIT or `meson test`.
They need only these Lua files, without building Pragtical. Editor tests use the
running editor's core modules. `tests/view.lua` requires the editor.

Meson sets `GHOSTTY_RUNTIME`, `GHOSTTY_PTY_RUNTIME`, and `GHOSTTY_ABI_PROBE` for its
LuaJIT test. The last variable names the C probe executable; without it, the
test's C-header comparison is skipped. Runtime metadata checks still run whenever
the Ghostty library loads. Logs are in each build's `meson-logs/testlog.txt`.

Coverage includes:

- Native POSIX PTYs: real TTY behavior, environment, cwd, dimensions, exit codes,
  and spawn failures.
- Native Windows ConPTY: argument quoting (including empty arguments and trailing
  slashes), Unicode environment/cwd, case-insensitive overrides, large input,
  resize, output backpressure/final output, cmd quoting, and repeated cleanup.
  Check all three child console handles with both null and redirected host
  streams, and verify that child output never reaches the host's redirected pipe.
- Backend: Unicode/wide/combining cells, styles, alternate screens, scrollback,
  retained callbacks under JIT load, application/Kitty keys, paste, focus/mouse,
  OSC links/cwd/clipboard, message limits, repeated creation, partial writes,
  shell arguments, final output, process exit, and reaping.
- Views: tab creation/drawing, input repeat, editor bindings, selection/copy,
  title/cwd events, close/exit policy, hidden drawer polling, links, and shell
  configuration. Scrollbar tests cover absolute row offsets, track clicks,
  repeated drags between frames, mouse protocol isolation, output, resize,
  small/hidden drawers, alternate screens, and clearing saved lines.

### Performance profiling

Use `scripts/profile.lua` through the global Pragtical install; `jit.p` and
`jit.v` are already bundled. Use a fresh `PRAGTICAL_USERDIR` so the installed
plugin cannot load before the checkout. Capture requires `btop` on PATH; replay
needs only the two runtime libraries.

Capture btop while alternating Down/Up at 30 keys per second, then replay the
same output before and after changes:

```sh
export PRAGTICAL_USERDIR="${TMPDIR:-/tmp}/ghostty-profile-user"
export SDL_VIDEO_DRIVER=dummy
export GHOSTTY_PROFILE_OUTPUT="${TMPDIR:-/tmp}/ghostty-before"
pragtical run scripts/profile.lua
export GHOSTTY_PROFILE_INPUT="$GHOSTTY_PROFILE_OUTPUT.frames"
GHOSTTY_PROFILE_MODE=replay pragtical run scripts/profile.lua
# After making changes, replay the original recording:
GHOSTTY_PROFILE_MODE=replay \
  GHOSTTY_PROFILE_OUTPUT="${TMPDIR:-/tmp}/ghostty-after" \
  pragtical run scripts/profile.lua
```

Outputs include `.jit.txt`, `.timings.txt`, and a final `.png`. Capture also
writes `.frames` and `.btop.conf`. Store these outside the repository because
recordings and screenshots contain the local process list.

| Environment variable | Purpose / default |
| --- | --- |
| `GHOSTTY_PROFILE_MODE` | `capture` or `replay`; defaults to `capture` |
| `GHOSTTY_PROFILE_OUTPUT` | Output prefix; defaults to `/tmp/ghostty-profile` |
| `GHOSTTY_PROFILE_INPUT` | Recording path; defaults to `<output prefix>.frames` |
| `GHOSTTY_PROFILE_SECONDS` | Capture duration; defaults to 8 seconds |
| `GHOSTTY_PROFILE_REPEATS` | Replay count; defaults to 10 after one warmup pass |
| `GHOSTTY_PROFILE_FORMAT` | `jit.p` format; defaults to `fl3i1m1` for functions/lines |
| `GHOSTTY_PROFILE_TRACE` | Optional output path for `jit.v` compilation logs |

Compare function/line profiles with `GHOSTTY_PROFILE_FORMAT=vf3i1m1`, which
separates GC, compiled Lua, and native samples. Samples attributed to an FFI call
site can be garbage collection, not time inside that C function. `jit.v`
confirms whether the hot loop compiles. Keep callback-capable feed/resize
methods off the JIT even when optimizing the render loop. Use the same recording,
font, and renderer for both runs.

Timing reports separate feed, snapshot extraction, draw submission, and native
frame completion. The dummy SDL driver uses the software surface backend and
replay bypasses editor pacing, so these are frame costs, not end-to-end input
latencies. Also check btop interactively for actual responsiveness. Snapshot
reuse tests, decorated-space/selection/wide-cursor tests, and image comparisons
cover the rendering optimization; preserve them when changing the cache.

### Windows Pragtical and Wine

Read `AGENTS.md` in the Pragtical source checkout before working on the editor.
Its cross file is `resources/cross/linux-mingw32-x86_64.ini`. From that checkout,
configure and build with:

```sh
meson setup build-windows \
  --cross-file resources/cross/linux-mingw32-x86_64.ini -Doptimization=3
meson compile -C build-windows
```

Use a runnable Windows Pragtical tree with `pragtical.exe`, `pragtical.com`, its
data directories/fonts, and the generated `start.lua` installed as
`data/core/start.lua`. Copy `subprojects/widget` from the editor checkout to
`data/widget` when assembling the tree manually. Create a `user` directory and
copy the plugin, including both DLLs, into `data/plugins/ghostty`.

From the plugin project in a Windows environment:

```sh
pragtical.com run -n scripts/test-windows.lua
```

The harness runs both Lua suites and explicitly exits with the test report. It
selects `COMSPEC`/cmd rather than inheriting a Linux shell. Keep the runner's
standard handles intact: clearing them hid the redirected-stream bug that also
affected native Windows CI. The transport must isolate child streams itself.

From this plugin's root, point to the runnable Windows editor directory and let
`winepath` convert the probe and script paths:

```sh
pragtical_windows_dir=/path/to/pragtical-windows
export WINEPREFIX="${TMPDIR:-/tmp}/ghostty-wine"
export WINEDEBUG=-all
export WINEDLLOVERRIDES=mscoree,mshtml=d
SDL_VIDEO_DRIVER=dummy \
  GHOSTTY_ABI_PROBE="$(winepath -w "$PWD/build-windows/abi-probe.exe")" \
  wine "$pragtical_windows_dir/pragtical.com" run -n \
  "$(winepath -w "$PWD/scripts/test-windows.lua")"
```

Use the same Wine prefix for building and testing. Wine may stub
`ResizePseudoConsole`, so the C suite skips the resize-effect assertion under
Wine while retaining the request/I/O checks. Native Windows CI runs the actual
resize assertion.
For interactive cmd prompt tests, use `cmd.exe /d`; `/q` suppresses the prompt.

### Visual checks and validation

```sh
SDL_VIDEO_DRIVER=dummy pragtical run scripts/preview.lua
```

This writes `/tmp/pragtical-ghostty-preview.png` with colors, styles, Unicode,
links, and a cursor. Use `run` without `-n` for this preview so the command exits.
For real keyboard/mouse/TUI behavior, also test in an ordinary editor window.

Choose checks that exercise the changed behavior:

- For upstream or FFI changes, run the Meson and editor suites, and compare
  generated declarations with GCC and Clang.
- For input changes, check Neovim's `:` command, shifted text, Space, repeats,
  and Kitty key releases in an interactive terminal.
- For PTY changes, run the platform's native transport suite. Keep redirected
  host handles intact when testing ConPTY. POSIX-specific backend cases are
  excluded on Windows; its native suite covers large writes and cleanup.
- For memory and cleanup changes, use AddressSanitizer/UndefinedBehaviorSanitizer
  where supported.
- For palette changes, inspect previews with dark, light, and monochrome themes.
- For packaging changes, check the release manifest and plugin-manager
  installation of Lua plus both libraries. Validate downloads from the release
  separately from installations using local artifacts.

Report which checks actually ran and distinguish native, Wine, and CI results.
Avoid rebuilding every platform for a documentation-only change.

## Configuration, usage, and Lua API

Define `config_spec` options explicitly with labels, descriptions, paths, types,
and defaults, then merge defaults with the user's configuration. Pragtical's
`plugins/settings.lua` accepts type names case-insensitively; write them in
lowercase (`string`, `number`, `toggle`, `selection`). Other supported types are
listed in `settings.type`; `text` is unsupported and silently omits the control.
Use a `selection` with label/value pairs for the OSC 52 policy. Shell
and library overrides use `string` so executable/library names and empty optional
overrides remain valid. When changing the spec, check the generated settings UI
as well as the config values.

Configuration lives in `config.plugins.ghostty`. Important defaults:

| Setting | Default / behavior |
| --- | --- |
| `shell` | `SHELL`, then Windows `COMSPEC`, then `cmd.exe` on Windows or `/bin/sh` elsewhere |
| `arguments`, `command_arguments` | `nil`, selecting flags for the shell |
| `environment` | Empty table, merged with inherited process environment |
| `env` | Additional overrides taking precedence over `environment` |
| `term` | `xterm-256color`; `COLORTERM=truecolor` is also supplied |
| `drawer_height`, `max_scrollback` | 300 pixels, 10000 lines |
| `close_on_exit`, `agent_close_on_exit` | `clean_exit`, `never` |
| `click_modifier` | Cmd on macOS, Ctrl elsewhere |
| `osc52`, `osc_max_bytes` | `ask`, 1 MiB |
| `paste_warning` | `true` |
| `poll_interval` | `nil`: follow current `config.fps`; numeric seconds override, minimum 1 ms |
| `read_budget`, `write_limit` | 256 KiB each for reads/writes per session per poll, 4 MiB queued input |

Optional `font` overrides the terminal's renderer font or font group.
`foreground`, `background`, and `cursor` override theme colors with RGB(A) tables;
`mac_option_as_meta = false` disables Option-as-Alt encoding. `terminfo` supplies
a TERMINFO directory. The plugin does not bundle Ghostty terminfo: configuring
`term = "xterm-ghostty"` requires installing that terminfo separately.

The first 16 ANSI colors come from `palette.lua`. It selects syntax accents by
hue, falls back to UI/status accents, and generates missing hues using the theme's
saturation/lightness. Alpha in theme accents is composited against the effective
terminal background. Normal and bright accents target at least 4.5:1 contrast;
bright black targets 3:1, while ANSI black remains a background shade. Bright
variants move toward white on dark backgrounds and black on light backgrounds.
Neutral colors follow the effective foreground/background, including overrides.

`TerminalView` compares color-value signatures, including syntax colors, so open
terminals update even when a theme mutates an existing table. Generate only when
these values change. `Terminal:set_palette` reads all 256 default entries, replaces
0–15, and sends a `GhosttyColorRgb[256]` through FFI. Keep indices 16–255 unchanged
and let Ghostty preserve application OSC 4 overrides; OSC 104 should restore the
new defaults. Backend tests cover actual rendered cells, extended colors, and
OSC resets; the view test covers live theme changes. `scripts/preview.lua` draws
both normal and bright ANSI rows. Ghostty's own theme files are not loaded.
No sibling theme repository is needed at runtime.

Shell classification uses the executable basename, ignoring case and `.exe`:

| Shell | Default startup flags | Command-string flags |
| --- | --- | --- |
| cmd | `/d` | `/s /c` |
| powershell / pwsh | `-NoLogo` | `-Command` |
| Other shells | `-l` | `-c` |

`arguments = {}` suppresses startup flags. Explicit argument tables override
defaults. Command strings require `shell = true`; a command array bypasses shell
interpretation. `command = false` creates an emulation-only terminal for tests.
Reject NUL bytes in argv/cwd/environment and invalid environment keys. File drops
use shell-specific quoting: double quotes for cmd, single quotes with doubled
apostrophes for PowerShell, and POSIX single-quote escaping for Unix shells.

UI shortcuts are Alt+T to toggle the drawer, Shift+Alt+T to open or focus it,
Ctrl+Shift+backtick for a tab,
Ctrl+Shift+C/V for copy/paste, and Ctrl+Shift+W to close. Cmd+C/V also work on
macOS. Ctrl+C reaches the process; Ctrl+Shift+P and Ctrl+Tab retain their editor
actions. Shift overrides terminal mouse tracking for selection/scrolling.
Ctrl-click (Cmd-click on macOS) opens links and `path:line:column` references.
The `click_modifier` selection appears as **Open Links Modifier** in Settings.
Its platform-specific choices apply to new terminals.

The public API is exposed by `require "plugins.ghostty"`:

```lua
local core = require "core"
local ghostty = require "plugins.ghostty"

ghostty.open_tab {
  command = { "make", "-j4" },
  cwd = core.root_project().path,
  close_on_exit = "never",
}
ghostty.open_drawer { command = "git status", shell = true }
local unsubscribe = ghostty.on("terminal-exited", function(event)
  core.log("Terminal exited: code=%d signal=%d", event.code, event.signal)
end)
```

`ghostty.new_terminal(options)` constructs a TerminalView; the class is exported
as `ghostty.TerminalView`. Event callbacks run on the editor thread and listener
errors do not stop polling. Events are `terminal-created`, `terminal-closed`,
`terminal-exited`, `title-changed`, `cwd-changed`, `bell`, `notification`,
`clipboard-write-request`, `clipboard-write-accepted`, `clipboard-write-denied`,
and `link-opened`. `ghostty.on` returns an unsubscribe function.

## Current limitations

Inline terminal graphics, terminal search, and restoring sessions after an
editor restart are not implemented. Text selection is limited to the visible
viewport; use the scrollbar, mouse wheel, or scroll commands to browse history.

## CI, manifest, and release workflow

`manifest.json` lists ten mandatory files: VT and PTY for each of the five
architectures. URLs use
`https://github.com/pragtical/ghostty/releases/download/latest/<filename>`.
Each entry uses `checksum: "SKIP"`, following the Tree-sitter plugin's moving
latest-release convention. The plugin manager downloads every matching platform
entry using its URL basename; installation needs no archive extraction or build
hook. Keep filenames and architectures synchronized across Meson, the loader,
the manifest, and the workflow.

The workflow installs Zig **0.16.0** through **`mlugg/setup-zig@v2`**, as requested
by the user. Native jobs use Ubuntu 24.04 x86_64/ARM, macOS 15 ARM/Intel, and
Windows with MSYS2 UCRT64. Each job builds and runs Meson tests; Linux/macOS also
check regenerated declarations. CI currently tests the native transport and
standalone FFI backend, not the full Pragtical view suite. Both build jobs fetch
Pragtical's `data/core` from commit `d3db654789e96df38f034bef7722ea0472f2393d`
(v3.13.0) into the ignored `.test-pragtical` directory and set
`PRAGTICAL_DATA_DIR` for the standalone suite. These test dependencies are not
included in the plugin package.

Before upload, Linux x86_64 also tests its stripped libraries under QEMU with
an older CPU model to catch accidental use of the build runner's CPU features.
`GHOSTTY_TEST_VT_ONLY=1` limits this standalone run to VT/FFI tests. QEMU 8.2
fails a PTY child-output assertion that passes natively; process and terminal
I/O integration remain covered by the full native suites on every platform.

CI configures `-Dstrip=true` and uses `meson install --tags runtime` into
`package/plugins/ghostty`. Each Actions artifact is named `ghostty-<arch>` and
contains exactly the two stripped runtime libraries from that directory.
Publishing waits for all builds and validates all ten files. Every release
also receives `SHA256SUMS`.

- Pushes to `master`/`main` publish the `continuous` prerelease.
- Version tags matching `v<manifest version>` publish a versioned release and
  `latest`, update the `latest` branch/tag used by the plugin manager, and also
  update `continuous`.
- Manual runs publish `continuous`; optional `release_tag` also publishes that
  version and `latest`. The tag must match the selected commit's manifest.
- Pull requests build/test without publishing.
- Only the release job gets `contents: write`; it uses `GITHUB_TOKEN` through
  `GH_TOKEN` and identifies the current repository through `GH_REPO`.
- Publishing is serialized with concurrency group `ghostty-release`. Moving
  tags/branches are force-updated, and existing release assets are overwritten.

The GitHub repository is `pragtical/ghostty`. Push a `v<manifest version>` tag
or dispatch the workflow with that tag to publish a release. Keep `meson.build`
and manifest versions aligned. Routine local validation does not require
publishing anything.

Useful checks:

```sh
python3 scripts/check-release.py
python3 scripts/stage-libraries.py build artifacts/x86_64-linux
python3 scripts/check-release.py artifacts/x86_64-linux --arch x86_64-linux
actionlint .github/workflows/build.yml
```

For all-platform publication, combine the ten built binaries in a clean directory:

```sh
python3 scripts/check-release.py artifacts/release \
  --checksums artifacts/release/SHA256SUMS
```

The validator checks exact manifest URLs, architectures, mandatory status,
checksum convention, expected filenames, and nonempty binaries. Without `--arch`
it requires all ten assets; do not use that mode on a single platform's pair.

## Development and maintenance

Find Pragtical, Zig, and optional tools such as `actionlint` through `PATH` or
explicit configuration. Inspect existing Meson options before reusing a build
directory, especially after moving a checkout or changing the Zig version.
Build directories, compiler caches, Wine prefixes, and editor staging trees
must be created as needed; their presence or layout is not a project requirement.
Check whether a plugin installation is a copy or a symlink before updating it.

Related Pragtical projects include the editor (cross-build practices),
Tree-sitter plugin (FFI loading and release conventions), terminal plugin
(shell configuration), plugin manager (installer behavior), and central plugin
index. Their checkouts can live anywhere. Read each project's instructions
before editing it.

Keep generated libraries, build/package directories, caches, and extracted
upstream sources out of source control; `.gitignore` already covers them.
Publish only the two runtime libraries from the staged installation;
intermediate build outputs and logs can contain absolute paths from the builder.
Preserve the MIT notices in `LICENSE`, `plugins/ghostty/LICENSE`, and
`plugins/ghostty/LICENSE.ghostty`, including Manuj Bhatia's attribution in the
adapted UI. Prefer focused changes and the existing Lua/C/Python style. When
reporting validation, distinguish native execution, Wine execution, configured
CI coverage, and checks that were actually run.
