#!/usr/bin/env python3
"""Build the pinned Ghostty VT library and stage one real shared library."""

import pathlib
import shutil
import subprocess
import sys

source, output = (
    pathlib.Path(sys.argv[1]).resolve(),
    pathlib.Path(sys.argv[2]).resolve(),
)
global_cache = pathlib.Path(sys.argv[4]).resolve()
platform, target = sys.argv[5:7]
zig = shutil.which(sys.argv[3])
if not zig:
    sys.exit("Zig 0.16.0 is required. Set -Dzig=/path/to/zig.")
if subprocess.check_output([zig, "version"], text=True).strip() != "0.16.0":
    sys.exit(
        "This Ghostty revision requires Zig 0.16.0. Set -Dzig=/path/to/zig."
    )
prefix = output.parent / "ghostty-output"
subprocess.run(
    [
        zig,
        "build",
        # Match the pinned build.zig.zon; do not detect this plugin's Git tags.
        "-Dversion-string=1.3.2-dev",
        "-Demit-lib-vt=true",
        "-Demit-xcframework=false",
        "-Doptimize=ReleaseFast",
        "-Dtarget=" + target,
        # Release binaries must also run on CPUs older than the CI runner.
        "-Dcpu=baseline",
        "--prefix",
        str(prefix),
        "--cache-dir",
        str(output.parent / "ghostty-cache"),
        "--global-cache-dir",
        str(global_cache),
    ],
    cwd=source,
    check=True,
)
library = {
    "darwin": ("lib", "libghostty-vt.dylib"),
    "linux": ("lib", "libghostty-vt.so"),
    "windows": ("bin", "ghostty-vt.dll"),
}[platform]
shutil.copyfile(prefix.joinpath(*library), output)
# C dependencies may retain debug paths even in a ReleaseFast Zig build.
# Meson cannot strip custom targets on install, so honor its strip option here.
# Otherwise strip debug metadata to keep private paths out of the library.
strip_args = ["-S"]
if sys.argv[8] == "true":
    strip_args = ["-S", "-x"] if platform == "darwin" else []
subprocess.run([sys.argv[7], *strip_args, str(output)], check=True)
