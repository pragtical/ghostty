#!/usr/bin/env python3
"""Check plugin-manager downloads against staged release binaries."""

import argparse
import hashlib
import json
import pathlib
import re

ARCHES = (
    "x86_64-linux",
    "aarch64-linux",
    "x86_64-darwin",
    "aarch64-darwin",
    "x86_64-windows",
)
ROOT = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("directory", nargs="?", type=pathlib.Path)
parser.add_argument("--arch", choices=ARCHES)
parser.add_argument("--checksums", type=pathlib.Path)
args = parser.parse_args()

(addon,) = json.loads((ROOT / "manifest.json").read_text())["addons"]
if addon["id"] != "ghostty" or addon["path"] != "plugins/ghostty":
    parser.error("Expected the Ghostty plugin directory in manifest.json")
if not re.fullmatch(r"\d+\.\d+\.\d+(?:[.-][0-9A-Za-z.-]+)?", addon["version"]):
    parser.error("Invalid release version in manifest.json")
expected = {}
for arch in ARCHES:
    suffix = "dll" if arch.endswith("-windows") else "so"
    for library in ("vt", "pty"):
        expected[f"ghostty-{library}.{arch}.{suffix}"] = arch
files = addon["files"]
base = "https://github.com/pragtical/ghostty/releases/download/latest/"
downloads = {file["url"]: file for file in files}
if len(files) != len(expected) or set(downloads) != {
    base + name for name in expected
}:
    parser.error(
        "The manifest must list both libraries for all five architectures"
    )
for name, arch in expected.items():
    file = downloads[base + name]
    if (
        file["arch"] != arch
        or file.get("path", name) != name
        or file.get("optional")
        or file.get("checksum") != "SKIP"
    ):
        parser.error(f"Incorrect plugin-manager download entry for {name}")

if args.directory:
    names = {
        name
        for name, arch in expected.items()
        if not args.arch or arch == args.arch
    }
    staged = {
        p.name for p in args.directory.iterdir() if p.suffix in (".so", ".dll")
    }
    if names != staged:
        parser.error(
            f"Incorrect assets: missing {sorted(names - staged)}, "
            f"unexpected {sorted(staged - names)}"
        )
    sums = []
    for name in sorted(names):
        data = (args.directory / name).read_bytes()
        if not data:
            parser.error(f"Empty release asset: {name}")
        sums.append(f"{hashlib.sha256(data).hexdigest()}  {name}\n")
    if args.checksums:
        args.checksums.write_text("".join(sums))
    print(f"Verified {len(names)} release binaries against manifest.json")
elif args.checksums:
    parser.error("--checksums requires a release directory")
else:
    print("Verified ten downloads covering five architectures")
