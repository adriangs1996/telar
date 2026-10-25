#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


GHOSTTY_COMMIT = "a4edca2a90d6cf89900bb058e71cb6860cec78c5"
GHOSTTY_REPOSITORY = "https://github.com/ghostty-org/ghostty.git"


def run(arguments, directory):
    subprocess.run(arguments, cwd=directory, check=True)


def main():
    parser = argparse.ArgumentParser(description="Build the pinned libghostty-vt C API for Telar")
    parser.add_argument("--build-dir", type=Path, required=True)
    parser.add_argument("--prefix", type=Path, required=True)
    parser.add_argument("--source", type=Path, help="Optional existing source at the pinned commit; copied before patching")
    parser.add_argument("--zig", default="zig")
    arguments = parser.parse_args()
    build = arguments.build_dir.resolve()
    prefix = arguments.prefix.resolve()
    patch = Path(__file__).resolve().parent.parent / "vendor" / "ghostty-vt-state.patch"
    expected = {"commit": GHOSTTY_COMMIT, "patch_sha256": hashlib.sha256(patch.read_bytes()).hexdigest()}
    marker = build / "telar-ghostty-build.json"
    source = build / "source"

    if marker.exists():
        if json.loads(marker.read_text()) != expected:
            raise RuntimeError("Dependency version changed; use a new build directory")
    else:
        if source.exists():
            raise RuntimeError("Source directory already exists without a matching build manifest")
        build.mkdir(parents=True, exist_ok=True)
        if arguments.source:
            shutil.copytree(arguments.source.resolve(), source, ignore=shutil.ignore_patterns(".git", ".zig-cache", "zig-out"))
        else:
            source.mkdir()
            run(["git", "init", "--quiet"], source)
            run(["git", "remote", "add", "origin", GHOSTTY_REPOSITORY], source)
            run(["git", "fetch", "--depth=1", "origin", GHOSTTY_COMMIT], source)
            run(["git", "checkout", "--detach", "FETCH_HEAD"], source)

        run(["git", "apply", "--check", str(patch)], source)
        run(["git", "apply", str(patch)], source)
        marker.write_text(json.dumps(expected, indent=2) + "\n")

    run([
        arguments.zig, "build", "-Demit-lib-vt", "-Demit-xcframework=false",
        "-Doptimize=ReleaseFast", "--prefix", str(prefix),
    ], source)
    print(f"libghostty-vt installed at {prefix}")


if __name__ == "__main__":
    main()
