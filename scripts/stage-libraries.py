#!/usr/bin/env python3
"""Stage the runtime libraries using their actual Meson target paths."""

import json
import pathlib
import shutil
import subprocess
import sys

targets = json.loads(
    subprocess.check_output(
        [
            "meson",
            "introspect",
            sys.argv[1],
            "--targets",
        ],
        text=True,
    )
)
libraries = [
    pathlib.Path(target["filename"][0])
    for target in targets
    if target["name"] == "ghostty-vt"
    or target["name"].startswith("ghostty-pty.")
]
if len(libraries) != 2:
    sys.exit("Expected Ghostty VT and PTY library targets in the Meson build.")
destination = pathlib.Path(sys.argv[2])
destination.mkdir(parents=True, exist_ok=True)
for library in libraries:
    shutil.copy2(library, destination / library.name)
