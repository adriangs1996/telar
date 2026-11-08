#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


GHOSTTY_COMMIT = "df1c99c8a5ec32c73963e5dc3fad3c9df7a3d137"
GHOSTTY_APP_VERSION = "1.4.1-dev+df1c99c8"
GHOSTTY_REPOSITORY = "https://github.com/ghostty-org/ghostty.git"


def run(arguments, directory):
    subprocess.run(arguments, cwd=directory, check=True)


def install_codec_header(source, prefix, supplied=None):
    vendor = Path(__file__).resolve().parent.parent / "vendor"
    codec = json.loads((vendor / "wuffs-codec.json").read_text())
    header = supplied if supplied is not None else source / "zig-pkg" / codec["zig_package"] / codec["source_path"]
    if not header.is_file() or hashlib.sha256(header.read_bytes()).hexdigest() != codec["header_sha256"]:
        raise RuntimeError("Pinned Wuffs header missing or mismatched; supply its original release/c/wuffs-v0.4.c with --wuffs-header")
    target = prefix / codec["installed_path"]
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(header, target)
    license_path = prefix / "share/licenses/wuffs/LICENSE-MIT"
    license_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(vendor / "wuffs-LICENSE-MIT", license_path)


def main():
    parser = argparse.ArgumentParser(description="Build the pinned libghostty-vt C API for Telar")
    parser.add_argument("--build-dir", type=Path, required=True)
    parser.add_argument("--prefix", type=Path, required=True)
    parser.add_argument("--source", type=Path, help="Existing Git checkout containing the pinned commit; archives that immutable revision")
    parser.add_argument("--zig", default="zig")
    parser.add_argument("--wuffs-header", type=Path, help="Pinned generated header when Zig stores packages outside the source's zig-pkg directory")
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
            # Keep patch paths relative to this archive instead of the enclosing worktree.
            run(["git", "init", "--quiet"], source)
        else:
            source.mkdir()
            run(["git", "init", "--quiet"], source)
            run(["git", "remote", "add", "origin", GHOSTTY_REPOSITORY], source)
            run(["git", "fetch", "--depth=1", "origin", GHOSTTY_COMMIT], source)
            run(["git", "checkout", "--detach", "FETCH_HEAD"], source)

        run(["git", "apply", "--check", str(patch)], source)
        run(["git", "apply", str(patch)], source)
        marker.write_text(json.dumps(expected, indent=2) + "\n")

    if subprocess.check_output(["git", "rev-parse", "--show-toplevel"], cwd=source, text=True).strip() != str(source):
        raise RuntimeError("Dependency source is not an isolated checkout; use a new build directory")
    run(["git", "apply", "--reverse", "--check", str(patch)], source)

    run([
        arguments.zig, "build", "-j2", "-Demit-lib-vt", "-Demit-xcframework=false",
        "-Demit-macos-app=false", "-Demit-docs=false", "-Dversion-string=" + GHOSTTY_APP_VERSION,
        "-Doptimize=ReleaseFast", "--prefix", str(prefix),
    ], source)
    install_codec_header(source, prefix, arguments.wuffs_header)
    print(f"libghostty-vt prepared at {prefix}")


if __name__ == "__main__":
    main()
