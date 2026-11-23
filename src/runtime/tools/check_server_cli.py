"""Runtime server CLI checks that tests/server_cli_test.py runs against one telar binary."""
import os
from pathlib import Path
import select
import shutil
import signal
import socket as sockets
import stat
import struct
import subprocess
import tempfile
import threading
import time


FRAME_PREFIX = struct.Struct("<I")
HANDSHAKE_MAGIC = b"TELARIPC"
CLIENT_HELLO = 1
SERVER_ACCEPT = 2
SERVER_REJECT = 3
REJECT_INCOMPATIBLE_SCHEMA = 1


def wait_socket(path, present):
    deadline = time.monotonic() + 12
    while path.exists() != present:
        if time.monotonic() >= deadline:
            raise RuntimeError(f"Socket state did not become {present}: {path}")
        time.sleep(0.01)


def socket_handshake(path, schema):
    """A client of this schema is accepted on the runtime's socket."""
    hello = HANDSHAKE_MAGIC + bytes([CLIENT_HELLO]) + schema
    expected_payload = HANDSHAKE_MAGIC + bytes([SERVER_ACCEPT]) + schema
    expected = FRAME_PREFIX.pack(len(expected_payload)) + expected_payload
    with sockets.socket(sockets.AF_UNIX) as client:
        client.settimeout(10)
        client.connect(str(path))
        client.sendall(FRAME_PREFIX.pack(len(hello)) + hello)
        response = b""
        while len(response) < len(expected):
            chunk = client.recv(len(expected) - len(response))
            if not chunk:
                raise RuntimeError("The runtime ended before its handshake")
            response += chunk
        assert response == expected


def isolated_environment(root):
    """The environment of a user whose home, XDG directories and temporary files all live in `root`."""
    environment = {key: value for key, value in os.environ.items() if not key.startswith("TELAR_")}
    environment.update({"HOME": str(root / "home"), "XDG_RUNTIME_DIR": str(root / "run"),
                        "XDG_DATA_HOME": str(root / "data"), "XDG_CONFIG_HOME": str(root / "config"),
                        "XDG_CACHE_HOME": str(root / "cache"), "XDG_STATE_HOME": str(root / "state"), "TMPDIR": str(root)})
    (root / "home").mkdir(mode=0o700)
    (root / "run").mkdir(mode=0o700)
    return environment


def server_invoker(binary, environment):
    def invoke(*arguments, success=True):
        result = subprocess.run([str(binary), "server", *map(str, arguments)], env=environment,
                                capture_output=True, text=True, timeout=15)
        if success and result.returncode != 0:
            raise RuntimeError(f"CLI failed: {arguments}: {result.stderr}")
        return result
    return invoke


def check_unwritable_shell_integration(binary, checkpoint_probe):
    """A data home where the shell integration cannot be written still runs the runtime and its panes."""
    if os.geteuid() == 0:
        return
    with tempfile.TemporaryDirectory(prefix="telar-cli-", dir="/tmp") as directory:
        root = Path(directory).resolve()
        environment = isolated_environment(root)
        invoke = server_invoker(binary, environment)
        socket = root / "runtime.sock"
        scripts = root / "data/telar/shell-integration"
        scripts.mkdir(parents=True, mode=0o700)
        scripts.chmod(0o500)
        try:
            invoke("--background", "--socket", socket, "--no-config")
            wait_socket(socket, True)
            seeded = subprocess.run([str(checkpoint_probe), str(socket), "seed", str(root / "expected")],
                                    env=environment, capture_output=True, text=True, timeout=30)
            if seeded.returncode:
                raise RuntimeError(f"Panes did not open: {seeded.stderr.strip()}")
            wait_socket(socket, False)
        finally:
            scripts.chmod(0o700)
            if socket.exists():
                invoke("stop", "--socket", socket)


def stale_socket_is_not_running(binary, root, invoke, stop):
    """A socket file left by a runtime that crashed is no runtime: stop says so and endpoint
    starts one in its place, without anyone deleting the file by hand."""
    stale = root / "stale.sock"
    with sockets.socket(sockets.AF_UNIX) as listener:
        listener.bind(str(stale))
    assert stale.exists()
    result = invoke("stop", "--socket", stale)
    assert result.returncode == 0 and result.stdout == "telar runtime is not running\n", result
    try:
        assert invoke("endpoint", "--socket", stale).stdout.splitlines()[0] == str(stale)
    finally:
        stop(stale)


def endpoint_reports_runtime_start_failure(binary, root, environment):
    """A runtime that exits as it starts is reported at once, not after the ten seconds a
    slow start may take."""
    directory = root / "failing-runtime"
    directory.mkdir()
    shutil.copy2(binary, directory / "telar")
    (directory / "telar-runtime").write_text("#!/bin/sh\nexit 1\n")
    (directory / "telar-runtime").chmod(0o700)
    started = time.monotonic()
    result = subprocess.run([str(directory / "telar"), "server", "endpoint", "--socket", str(root / "failing.sock")],
                            env=environment, capture_output=True, text=True, timeout=30)
    assert result.returncode != 0 and time.monotonic() - started < 5, (result, time.monotonic() - started)


def endpoint_reports_runtime_of_another_build(root, invoke):
    """A runtime that rejects this build's wire schema is reported as another build, with the
    words the machine commands and the window read as one they cannot attach to, and endpoint
    neither prints the socket nor starts a runtime of its own over it."""
    path = root / "other-build.sock"
    reject = HANDSHAKE_MAGIC + bytes([SERVER_REJECT, REJECT_INCOMPATIBLE_SCHEMA]) + b"cqp00001"
    with sockets.socket(sockets.AF_UNIX) as listener:
        listener.bind(str(path))
        listener.listen(1)

        def answer():
            connection, _ = listener.accept()
            with connection:
                connection.recv(64)
                connection.sendall(FRAME_PREFIX.pack(len(reject)) + reject)

        runtime = threading.Thread(target=answer, daemon=True)
        runtime.start()
        result = invoke("endpoint", "--socket", path, success=False)
        runtime.join(timeout=5)
    assert result.returncode == 1 and result.stdout == "", result
    assert "telar protocol mismatch" in result.stderr, result


def check_runtime(binary, checkpoint_probe):
    with tempfile.TemporaryDirectory(prefix="telar-cli-", dir="/tmp") as directory:
        root = Path(directory).resolve()
        environment = isolated_environment(root)
        socket = root / "runtime.sock"
        invoke = server_invoker(binary, environment)

        def stop(path):
            result = invoke("stop", "--socket", path)
            wait_socket(path, False)
            return result.stdout

        try:
            assert stop(socket) == "telar runtime is not running\n"
            stale_socket_is_not_running(binary, root, invoke, stop)
            endpoint_reports_runtime_start_failure(binary, root, environment)
            endpoint_reports_runtime_of_another_build(root, invoke)
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
            socket_handshake(socket, schema)

            seeded = subprocess.run([str(checkpoint_probe), str(socket), "seed", str(root / "expected")],
                                    env=environment, capture_output=True, text=True, timeout=30)
            if seeded.returncode:
                raise RuntimeError(f"Checkpoint probe failed: {seeded.stderr.strip()}")
            wait_socket(socket, False)

            def verify_session():
                verified = subprocess.run([str(checkpoint_probe), str(socket), "verify", str(root / "expected")],
                                          env=environment, capture_output=True, text=True, timeout=30)
                if verified.returncode:
                    raise RuntimeError(f"Restored session differs: {verified.stderr.strip()}")
                wait_socket(socket, False)

            # A restart without --fresh restores the session the stopped runtime saved.
            invoke("--background", "--socket", socket, "--no-config")
            wait_socket(socket, True)
            verify_session()

            # SIGTERM, as a service manager sends it, stops the runtime as `telar server stop` does:
            # it exits 0, removes its socket and leaves a session the next start restores.
            runtime = subprocess.Popen([str(binary), "server", "--socket", str(socket), "--no-config"], env=environment,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            try:
                wait_socket(socket, True)
                runtime.send_signal(signal.SIGTERM)
                assert runtime.wait(timeout=15) == 0, runtime.stderr.read()
            finally:
                if runtime.poll() is None:
                    runtime.kill()
                    runtime.wait()
                runtime.stderr.close()
            assert not socket.exists()
            invoke("--background", "--socket", socket, "--no-config")
            wait_socket(socket, True)
            verify_session()

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
        finally:
            if socket.exists():
                stop(socket)
