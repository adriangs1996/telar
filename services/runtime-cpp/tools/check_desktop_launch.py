#!/usr/bin/env python3
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile

from check_server_cli import bridge_handshake, wait_socket


def check_layout(binary, probe, layout):
    with tempfile.TemporaryDirectory(prefix="telar-desktop-", dir="/tmp") as directory:
        root = Path(directory).resolve()
        home = root / "home"
        home.mkdir(mode=0o700)
        socket = root / "runtime.sock"
        installation = root / "installation with spaces"
        program_directory = installation / ("Contents/MacOS" if layout == "bundle" else "bin")
        runtime_directory = installation / {
            "adjacent": "bin", "bundle": "Contents/Resources/bin", "path": "commands",
        }[layout]
        program_directory.mkdir(parents=True)
        runtime_directory.mkdir(parents=True, exist_ok=True)
        program = program_directory / "desktop-launch-probe"
        runtime = runtime_directory / "telar"
        shutil.copy2(probe, program)
        shutil.copy2(binary, runtime)

        search_directory = runtime_directory
        if layout != "path":
            search_directory = root / "wrong-runtime"
            search_directory.mkdir()
            fallback = search_directory / "telar"
            fallback.write_text("#!/bin/sh\nprintf 'Unexpected PATH fallback\\n' >&2\nexit 93\n")
            fallback.chmod(0o700)

        environment = {key: value for key, value in os.environ.items() if not key.startswith(("TELAR_", "DYLD_"))}
        environment.update(HOME=str(home), SHELL="/bin/sh", TELAR_SOCKET=str(socket),
                           XDG_CONFIG_HOME=str(root / "config"), XDG_DATA_HOME=str(root / "data"),
                           XDG_CACHE_HOME=str(root / "cache"), XDG_STATE_HOME=str(root / "state"),
                           XDG_RUNTIME_DIR=str(root / "run"), TMPDIR=str(root),
                           PATH="/usr/bin:/bin:/usr/sbin:/sbin")
        home.joinpath(".profile").write_text('export PATH="' + str(search_directory) + ':$PATH"\n')

        def resolve():
            result = subprocess.run([str(program)], env=environment, capture_output=True, text=True, timeout=40)
            if result.returncode != 0:
                raise RuntimeError(result.stderr.strip())
            if result.stdout != f"{socket}\n":
                raise RuntimeError(f"Unexpected Desktop endpoint: {result.stdout!r}")

        try:
            resolve()
            first_inode = socket.stat().st_ino
            resolve()
            assert socket.stat().st_ino == first_inode
            assert stat.S_IMODE(socket.stat().st_mode) == 0o600
            bridge_handshake(runtime, socket, environment)
            stop = subprocess.run([str(runtime), "server", "stop"], env=environment,
                                  capture_output=True, text=True, check=True, timeout=15)
            assert stop.stdout == "telar runtime is stopping\n"
            wait_socket(socket, False)
            return {"autostart": True, "reuse": True, "private_socket": True,
                    "wire_handshake": True, "stop": True}
        finally:
            if socket.exists():
                subprocess.run([str(runtime), "server", "stop"], env=environment,
                               capture_output=True, timeout=15, check=True)
                wait_socket(socket, False)


def main():
    parser = argparse.ArgumentParser(description="Exercise Desktop's actual runtime discovery in isolated installation layouts")
    parser.add_argument("--cpp", type=Path, required=True)
    parser.add_argument("--zig", type=Path)
    parser.add_argument("--probe", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    binaries = {name: path.resolve() for name in ("zig", "cpp", "probe") if (path := getattr(arguments, name))}
    report = {"checked_at": datetime.now(timezone.utc).isoformat(), "acceptance": "functional_only",
              "binaries": {name: {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
                           for name, path in binaries.items()}, "cases": {}}
    try:
        for implementation in ("zig", "cpp"):
            if implementation not in binaries:
                continue
            for layout in ("adjacent", "bundle", "path"):
                result = check_layout(binaries[implementation], binaries["probe"], layout)
                report["cases"][f"{implementation}/{layout}"] = result
                print(f"{implementation}/{layout}: passed", flush=True)
        if "zig" in binaries:
            for layout in ("adjacent", "bundle", "path"):
                assert report["cases"][f"zig/{layout}"] == report["cases"][f"cpp/{layout}"]
    except Exception as error:
        report["failure"] = str(error)
        raise
    finally:
        arguments.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
