project('ghostty', 'c', version: '0.2.0', license: 'MIT',
  meson_version: '>= 0.60', default_options: ['c_std=c11', 'warning_level=2'])

platform = host_machine.system()
if platform not in ['linux', 'darwin', 'windows']
  error('The PTY backend supports Linux, macOS and Windows.')
endif
arch = get_option('arch_tuple')
if arch == ''
  arch = host_machine.cpu_family() + '-' + host_machine.system()
endif
plugin_dir = join_paths(get_option('data_dir'), 'plugins', 'ghostty')
cc = meson.get_compiler('c')
pty_deps = []
pty_source = 'src/pty.c'
suffix = 'so'
if platform == 'windows'
  pty_source = 'src/pty_windows.c'
  suffix = 'dll'
else
  pty_deps += cc.find_library('util', required: platform == 'linux')
endif
pty = shared_library('ghostty-pty.' + arch, pty_source,
  name_prefix: '', name_suffix: suffix, dependencies: pty_deps,
  install: true, install_dir: plugin_dir)

ghostty = subproject('ghostty', default_options: [
  'arch_tuple=' + arch,
  'data_dir=' + get_option('data_dir'),
  'zig=' + get_option('zig'),
])
vt = ghostty.get_variable('ghostty_vt')
ghostty_dep = ghostty.get_variable('ghostty_dep')

install_data(
  'plugins/ghostty/init.lua', 'plugins/ghostty/config.lua',
  'plugins/ghostty/shell.lua', 'plugins/ghostty/palette.lua',
  'plugins/ghostty/runtime.lua', 'plugins/ghostty/ffi_defs.lua',
  'plugins/ghostty/terminal.lua', 'plugins/ghostty/pty.lua',
  'plugins/ghostty/osc.lua',
  'plugins/ghostty/events.lua', 'plugins/ghostty/selection.lua',
  'plugins/ghostty/click_to_open.lua',
  'plugins/ghostty/LICENSE', 'plugins/ghostty/LICENSE.ghostty',
  install_dir: plugin_dir)

pty_test_source = platform == 'windows' ? 'tests/pty_windows.c' : 'tests/pty.c'
pty_test = executable('test-pty', pty_test_source, link_with: pty)
test('pty', pty_test, timeout: 60)
abi_test = executable('abi-probe', 'tests/abi.c', dependencies: ghostty_dep)
luajit = find_program('luajit', required: false)
if luajit.found() and not meson.is_cross_build()
  test('terminal-ffi', luajit,
    args: [meson.project_source_root() / 'tests/backend.lua'],
    env: ['GHOSTTY_RUNTIME=' + vt.full_path(),
      'GHOSTTY_PTY_RUNTIME=' + pty.full_path(),
      'GHOSTTY_ABI_PROBE=' + abi_test.full_path()],
    workdir: meson.project_source_root(), depends: [vt, abi_test], timeout: 30)
endif
