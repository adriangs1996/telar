#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


GHOSTTY_COMMIT = "df1c99c8a5ec32c73963e5dc3fad3c9df7a3d137"
GHOSTTY_APP_VERSION = "1.4.1-dev+df1c99c8"
GHOSTTY_REPOSITORY = "https://github.com/ghostty-org/ghostty.git"


def run(arguments, directory):
    subprocess.run(arguments, cwd=directory, check=True)


def main():
    parser = argparse.ArgumentParser(description="Build the pinned libghostty-vt C API for Telar")
    parser.add_argument("--build-dir", type=Path, required=True)
    parser.add_argument("--prefix", type=Path, required=True)
    parser.add_argument("--source", type=Path, help="Existing Git checkout containing the pinned commit; archives that immutable revision")
    parser.add_argument("--zig", default="zig")
    arguments = parser.parse_args()
    build = arguments.build_dir.resolve()
    prefix = arguments.prefix.resolve()
    patch = Path(__file__).resolve().parent.parent / "vendor" / "ghostty-vt-state.patch"
    expected = {"commit": GHOSTTY_COMMIT, "app_version": GHOSTTY_APP_VERSION, "patch_sha256": hashlib.sha256(patch.read_bytes()).hexdigest()}
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
            source.mkdir()
            checkout = arguments.source.resolve()
            with subprocess.Popen(["git", "archive", "--format=tar", GHOSTTY_COMMIT], cwd=checkout, stdout=subprocess.PIPE) as archive:
                try:
                    subprocess.run(["tar", "-xf", "-", "-C", str(source)], stdin=archive.stdout, check=True)
                finally:
                    archive.stdout.close()
                if archive.wait() != 0:
                    raise RuntimeError("Could not archive the immutable Ghostty revision")
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
        arguments.zig, "build", "-j2", "-Demit-lib-vt", "-Demit-xcframework=false",
        "-Demit-macos-app=false", "-Demit-docs=false", "-Dversion-string=" + GHOSTTY_APP_VERSION,
        "-Doptimize=ReleaseFast", "--prefix", str(prefix),
    ], source)
    print(f"libghostty-vt installed at {prefix}")


if __name__ == "__main__":
    main()
