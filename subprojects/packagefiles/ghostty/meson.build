project('ghostty-vt', 'c', version: '0.1.0-dev', license: 'MIT',
  meson_version: '>= 0.60', default_options: ['c_std=c11'])

arch = get_option('arch_tuple')
if arch == ''
  arch = host_machine.cpu_family() + '-' + host_machine.system()
endif

platform = host_machine.system()
suffix = platform == 'windows' ? 'dll' : 'so'
zig_target = 'native'
if platform == 'windows'
  zig_target = host_machine.cpu_family() + '-windows-gnu'
elif meson.is_cross_build()
  error('Cross compilation is currently supported for Windows targets only.')
endif
python = import('python').find_installation('python3')
strip = find_program('strip')
ghostty_vt = custom_target('ghostty-vt',
  output: 'ghostty-vt.' + arch + '.' + suffix,
  command: [python, files('build-vt.py'),
    meson.current_source_dir(), '@OUTPUT@', get_option('zig'),
    join_paths(meson.global_build_root(), 'zig-cache'), platform, zig_target,
    strip.full_path(), get_option('strip').to_string()],
  depend_files: files('build.zig', 'build.zig.zon', 'build-vt.py'),
  build_by_default: true,
  install: true,
  install_tag: 'runtime',
  install_dir: join_paths(get_option('data_dir'), 'plugins', 'ghostty'))

# LuaJIT loads the shared library directly; C ABI probes only need its headers.
ghostty_dep = declare_dependency(
  include_directories: include_directories('include'))
