#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


def run(binary, kind, root, probe, action):
    socket = root / "runtime.sock"
    environment = {key: value for key, value in os.environ.items() if not key.startswith("TELAR_")}
    environment.update({"XDG_CONFIG_HOME": str(root / "config"), "XDG_DATA_HOME": str(root / "data")})
    history = root / "history.db"
    environment["TELAR_HISTORY"] = str(history)
    command = [str(binary), "--socket", str(socket), "--history", str(history)]
    if kind == "zig":
        command = [str(binary), "server", "--socket", str(socket), "--no-config"]

    with (root / "server.log").open("w+") as log:
        server = subprocess.Popen(command, env=environment, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 15
            while not socket.exists():
                if server.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("Runtime did not start")
                time.sleep(0.01)
            subprocess.run([str(probe), str(socket), action, str(root / "expected")], check=True, timeout=30, env=environment)
            server.wait(timeout=10)
            if server.returncode != 0:
                raise RuntimeError(f"Runtime exited with {server.returncode}")
            checkpoint = (root / "session.ckpt").read_bytes()
            if checkpoint[:10] != b"TELARCKP\x0a\x00":
                raise RuntimeError("Missing version 10 checkpoint")
        except Exception:
            log.flush()
            log.seek(0)
            print(log.read())
            raise
        finally:
            if server.poll() is None:
                server.terminate()
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()


def main():
    parser = argparse.ArgumentParser(description="Restore real sessions across independent C++ and Zig runtimes")
    parser.add_argument("--zig", type=Path, required=True)
    parser.add_argument("--cpp", type=Path, required=True)
    parser.add_argument("--probe", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    binaries = {name: getattr(arguments, name).resolve() for name in ("zig", "cpp", "probe")}
    report = {"binaries": {name: {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()} for name, path in binaries.items()}, "cases": []}
    for sequence in (("zig", "cpp", "zig"), ("cpp", "zig", "cpp"), ("cpp", "cpp", "cpp")):
        with tempfile.TemporaryDirectory(prefix="telar-restore-", dir="/tmp") as directory:
            root = Path(directory)
            for index, implementation in enumerate(sequence):
                run(binaries[implementation], implementation, root, binaries["probe"], "seed" if index == 0 else "verify")
            report["cases"].append({"sequence": sequence, "passed": True})
            print(" -> ".join(sequence), "passed", flush=True)
    arguments.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
