#!/usr/bin/env python3
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


def environment_for(root):
    environment = {key: value for key, value in os.environ.items() if not key.startswith("TELAR_")}
    environment.update({key: str(root / key.lower()) for key in
                        ("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME")})
    environment.update({"TELAR_HISTORY": str(root / "history.db"), "SHELL": "/bin/sh"})
    return environment


def run_runtime(binary, probe, root, options, action):
    socket = root / "runtime.sock"
    command = [str(binary), "server", "--socket", str(socket), "--no-config", *options]
    environment = environment_for(root)
    with (root / "server.log").open("w+") as log:
        server = subprocess.Popen(command, env=environment, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 15
            while not socket.exists():
                if server.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError("Clone runtime did not start")
                time.sleep(0.01)
            subprocess.run([str(probe), str(socket), action, str(root / "expected")], env=environment,
                           check=True, capture_output=True, text=True, timeout=30)
            server.wait(timeout=10)
            assert server.returncode == 0
        except Exception as error:
            log.flush()
            log.seek(0)
            raise RuntimeError(f"{error}\n{log.read()}") from error
        finally:
            if server.poll() is None:
                server.terminate()
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()


def reject(binary, root, options):
    result = subprocess.run([str(binary), "server", "--socket", str(root / "runtime.sock"), *options],
                            env=environment_for(root), capture_output=True, text=True, timeout=15)
    assert result.returncode != 0, f"Clone unexpectedly accepted: {options}"
    return result.returncode


def run_background_clone(binary, probe, root, options):
    socket = root / "runtime.sock"
    environment = environment_for(root)
    subprocess.run([str(binary), "server", "--socket", str(socket), "--no-config", "--background", *options],
                   env=environment, check=True, capture_output=True, text=True, timeout=15)
    try:
        deadline = time.monotonic() + 15
        while not socket.exists():
            if time.monotonic() >= deadline:
                raise RuntimeError("Background clone runtime did not start")
            time.sleep(0.01)
        subprocess.run([str(probe), str(socket), "verify", str(root / "expected")], env=environment,
                       check=True, capture_output=True, text=True, timeout=30)
        while socket.exists():
            if time.monotonic() >= deadline:
                raise RuntimeError("Background clone runtime did not stop")
            time.sleep(0.01)
    finally:
        if socket.exists():
            subprocess.run([str(binary), "server", "stop", "--socket", str(socket)], env=environment,
                           capture_output=True, text=True, timeout=10)


def check_implementation(binary, probe, source, root):
    shutil.copyfile(source / "expected", root / "expected")
    checkpoint = source / "session.ckpt"
    source_socket = str(source / "runtime.sock")
    options = ["--clone-session", str(checkpoint), "--clone-from", source_socket]
    source_bytes = checkpoint.read_bytes()
    run_runtime(binary, probe, root, options, "verify")
    destination = root / "session.ckpt"
    copied = destination.read_bytes()
    assert copied.count(b"/bin/sh\0") == 3 and b"/bin/cat\0" not in copied
    marker = root / "runtime.sock.desktop-clone.json"
    expected_workspace = (source / "expected").read_text().split()[0]
    origin = json.loads(marker.read_text())
    assert origin == {"version": 1, "source_socket": source_socket, "workspaces": [expected_workspace]}
    assert destination.stat().st_mode & 0o777 == 0o600 and marker.stat().st_mode & 0o777 == 0o600
    assert checkpoint.read_bytes() == source_bytes

    checkpoint.rename(source / "temporarily-unavailable.ckpt")
    try:
        run_runtime(binary, probe, root, options, "verify")
        run_background_clone(binary, probe, root, options)
    finally:
        (source / "temporarily-unavailable.ckpt").rename(checkpoint)
    retained = destination.read_bytes()
    rejected = {}
    invalid = {
        "missing_origin_option": ["--no-config", "--clone-session", str(checkpoint)],
        "configuration_enabled": options,
        "fresh_conflict": ["--no-config", "--fresh", *options],
        "different_origin": ["--no-config", "--clone-session", str(checkpoint), "--clone-from", str(source / "other.sock")],
        "same_checkpoint": ["--no-config", "--clone-session", str(destination), "--clone-from", source_socket],
        "same_socket": ["--no-config", "--clone-session", str(checkpoint), "--clone-from", str(root / "runtime.sock")],
        "relative_source": ["--no-config", "--clone-session", "relative.ckpt", "--clone-from", source_socket],
    }
    for name, arguments in invalid.items():
        rejected[name] = reject(binary, root, arguments)
        assert destination.read_bytes() == retained
    marker.unlink()
    rejected["unmarked_destination"] = reject(binary, root, ["--no-config", *options])
    assert destination.read_bytes() == retained
    marker.write_text(json.dumps(origin))
    marker.chmod(0o600)
    run_runtime(binary, probe, root, ["--fresh"], "empty")
    assert not marker.exists() and marker.with_name(marker.name + ".previous").exists()
    assert (root / "session.ckpt.previous").read_bytes() == retained
    assert checkpoint.read_bytes() == source_bytes
    return {"structure_and_layout": True, "fresh_shells": True, "source_preserved": True,
            "restart_without_source": True, "background_clone": True, "private_files": True, "fresh_origin_preserved": True,
            "refusals": rejected}


def main():
    parser = argparse.ArgumentParser(description="Compare Desktop session cloning with the Zig runtime")
    for name in ("zig", "cpp", "probe", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    arguments = parser.parse_args()
    binaries = {name: getattr(arguments, name).resolve() for name in ("zig", "cpp", "probe")}
    report = {"checked_at": datetime.now(timezone.utc).isoformat(), "binaries": {
        name: {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
        for name, path in binaries.items()}, "cases": {}}
    try:
        with tempfile.TemporaryDirectory(prefix="telar-clone-parity-", dir="/tmp") as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir(mode=0o700)
            run_runtime(binaries["zig"], binaries["probe"], source, [], "seed")
            for implementation in ("zig", "cpp"):
                destination = root / implementation
                destination.mkdir(mode=0o700)
                report["cases"][implementation] = check_implementation(binaries[implementation], binaries["probe"], source, destination)
                print(implementation, "clone checks passed", flush=True)
            assert report["cases"]["zig"] == report["cases"]["cpp"]
    except Exception as error:
        report["failure"] = str(error)
        raise
    finally:
        arguments.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
