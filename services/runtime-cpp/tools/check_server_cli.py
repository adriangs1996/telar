#!/usr/bin/env python3
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import select
import stat
import struct
import subprocess
import tempfile
import time


FRAME_PREFIX = struct.Struct("<I")
HANDSHAKE_MAGIC = b"TELARIPC"
CLIENT_HELLO = 1
SERVER_ACCEPT = 2


def wait_socket(path, present):
    deadline = time.monotonic() + 12
    while path.exists() != present:
        if time.monotonic() >= deadline:
            raise RuntimeError(f"Socket state did not become {present}: {path}")
        time.sleep(0.01)


def bridge_handshake(binary, socket, environment, schema):
    bridge = subprocess.Popen([str(binary), "server", "bridge", "--socket", str(socket)], env=environment,
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        hello = HANDSHAKE_MAGIC + bytes([CLIENT_HELLO]) + schema
        bridge.stdin.write(FRAME_PREFIX.pack(len(hello)) + hello)
        bridge.stdin.flush()
        response = b""
        deadline = time.monotonic() + 10
        expected_payload = HANDSHAKE_MAGIC + bytes([SERVER_ACCEPT]) + schema
        expected = FRAME_PREFIX.pack(len(expected_payload)) + expected_payload
        while len(response) < len(expected):
            ready, _, _ = select.select([bridge.stdout], [], [], max(0, deadline - time.monotonic()))
            if not ready:
                raise RuntimeError("Bridge handshake timed out")
            chunk = os.read(bridge.stdout.fileno(), len(expected) - len(response))
            if not chunk:
                raise RuntimeError("Bridge ended before its handshake")
            response += chunk
        assert response == expected
        bridge.stdin.close()
        assert bridge.wait(timeout=5) == 0
    finally:
        if bridge.poll() is None:
            bridge.kill()
            bridge.wait()


def check_runtime(binary, checkpoint_probe):
    with tempfile.TemporaryDirectory(prefix="telar-cli-", dir="/tmp") as directory:
        root = Path(directory).resolve()
        environment = {key: value for key, value in os.environ.items() if not key.startswith("TELAR_")}
        environment.update({"HOME": str(root / "home"), "XDG_RUNTIME_DIR": str(root / "run"),
                            "XDG_DATA_HOME": str(root / "data"), "XDG_CONFIG_HOME": str(root / "config"),
                            "XDG_CACHE_HOME": str(root / "cache"), "XDG_STATE_HOME": str(root / "state"), "TMPDIR": str(root)})
        (root / "home").mkdir(mode=0o700)
        (root / "run").mkdir(mode=0o700)
        socket = root / "runtime.sock"

        def invoke(*arguments, success=True):
            result = subprocess.run([str(binary), "server", *map(str, arguments)], env=environment,
                                    capture_output=True, text=True, timeout=15)
            if success and result.returncode != 0:
                raise RuntimeError(f"CLI failed: {arguments}: {result.stderr}")
            return result

        def stop(path):
            result = invoke("stop", "--socket", path)
            wait_socket(path, False)
            return result.stdout

        try:
            assert stop(socket) == "telar runtime is not running\n"
            endpoint = invoke("endpoint", "--socket", socket).stdout
            lines = endpoint.splitlines()
            assert len(lines) == 2 and lines[0] == str(socket)
            schema = lines[1].encode("ascii")
            assert len(schema) == 8
            inode = socket.stat().st_ino
            assert invoke("endpoint", "--socket", socket).stdout == endpoint
            assert socket.stat().st_ino == inode
            assert stat.S_IMODE(socket.stat().st_mode) == 0o600
            history = root / "data/telar/history.db"
            assert history.exists() and stat.S_IMODE(history.stat().st_mode) == 0o600
            bridge_handshake(binary, socket, environment, schema)

            seeded = subprocess.run([str(checkpoint_probe), str(socket), "seed", str(root / "expected")],
                                    env=environment, capture_output=True, text=True, timeout=30)
            if seeded.returncode:
                raise RuntimeError(f"Checkpoint probe failed: {seeded.stderr.strip()}")
            wait_socket(socket, False)
            checkpoint = history.with_name("session.ckpt")
            previous = checkpoint.read_bytes()
            invoke("--background", "--socket", socket, "--fresh", "--no-config")
            wait_socket(socket, True)
            preserved = checkpoint.with_name("session.ckpt.previous")
            assert preserved.read_bytes() == previous
            assert invoke("--socket", socket, "--fresh", "--no-config", success=False).returncode != 0
            assert preserved.read_bytes() == previous
            assert stop(socket) == "telar runtime is stopping\n"

            for settings, expected in (
                ({"TELAR_SOCKET_PATH": str(root / "pane.sock")}, root / "pane.sock"),
                ({"TELAR_SOCKET_PATH": str(root / "pane.sock"), "TELAR_SOCKET": str(root / "override.sock")}, root / "override.sock"),
                ({}, root / "run/telar/runtime.sock"),
            ):
                for name in ("TELAR_SOCKET_PATH", "TELAR_SOCKET"):
                    environment.pop(name, None)
                environment.update(settings)
                try:
                    assert invoke("endpoint").stdout == f"{expected}\n{schema.decode('ascii')}\n"
                    stop(expected)
                finally:
                    if expected.exists():
                        stop(expected)

            for arguments in (("--socket",), ("stop", "endpoint"), ("stop", "--fresh"), ("--background", "--daemonized")):
                assert invoke(*arguments, success=False).returncode == 1
            return {"endpoint_and_autostart": True, "stop": True, "bridge": True, "private_paths": True,
                    "history_default": True, "fresh_preserves_previous": True, "active_fresh_rejected": True,
                    "socket_precedence": True, "invalid_arguments_rejected": True}
        finally:
            if socket.exists():
                stop(socket)


def main():
    parser = argparse.ArgumentParser(description="Compare runtime server CLI behavior in isolated directories")
    for name in ("zig", "cpp", "checkpoint-probe", "output"):
        parser.add_argument(f"--{name}", type=Path, required=True)
    arguments = parser.parse_args()
    binaries = {name: getattr(arguments, name).resolve() for name in ("zig", "cpp", "checkpoint_probe")}
    report = {"measured_at": datetime.now(timezone.utc).isoformat(),
              "binaries": {name: {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()} for name, path in binaries.items()}}
    for implementation in ("zig", "cpp"):
        report[implementation] = check_runtime(binaries[implementation], binaries["checkpoint_probe"])
        print(f"{implementation}: server CLI checks passed", flush=True)
    arguments.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
