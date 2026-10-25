#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import sqlite3
import subprocess
import tempfile
import time

from check_history_availability import fingerprint


def check(binary, probe, mode):
    with tempfile.TemporaryDirectory(prefix="telar-history-queue-", dir="/tmp") as temporary:
        root = Path(temporary)
        endpoint = root / "runtime.sock"
        database = root / "history.db"
        environment = {key: value for key, value in os.environ.items() if not key.startswith(("TELAR_", "DYLD_"))}
        for name in ("HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"):
            directory = root / name.lower()
            directory.mkdir(mode=0o700)
            environment[name] = str(directory)
        environment.update(SHELL="/bin/sh", TERM="xterm-256color")
        configuration = root / "runtime.lua"
        configuration.write_text('return {api_version=2,runtime={history={path=' + json.dumps(str(database)) + '},proxy={enabled=false},session={persist=false}}}\n')
        dump = root / "responses.bin"
        with (root / "server.log").open("w+") as log:
            server = subprocess.Popen([str(binary), "server", "--socket", str(endpoint), "--config", str(configuration)], env=environment, stdout=log, stderr=log)
            client = None
            result = {}
            try:
                deadline = time.monotonic() + 15
                while not endpoint.exists():
                    if server.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError("Runtime did not start")
                    time.sleep(0.01)
                with sqlite3.connect(database, timeout=5) as lock:
                    lock.execute("BEGIN IMMEDIATE")
                    command = [str(probe), str(endpoint), str(dump)] + ([mode] if mode else [])
                    client = subprocess.Popen(command, env=environment,
                                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                    readable, _, _ = select.select([client.stdout], [], [], 3)
                    if not readable or client.stdout.readline() != "queued\n":
                        raise RuntimeError("History requests did not enter the queue while SQLite was locked")
                    lock.rollback()
                stdout, stderr = client.communicate("\n", timeout=15)
                if client.returncode:
                    raise RuntimeError(f"Probe failed: {stderr}")
                contents = dump.read_bytes()
                result = {"passed": True, "responses_sha256": hashlib.sha256(contents).hexdigest(), "response_bytes": len(contents)}
            except Exception as error:
                result = {"passed": False, "error": str(error)}
            finally:
                if client is not None and client.poll() is None:
                    client.kill()
                    client.wait()
                if server.poll() is None:
                    server.terminate()
                try:
                    server.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()
                log.flush()
                log.seek(0)
                diagnostics = log.read()
                if not result.get("passed") or server.returncode not in (0, -15) or "ERROR: AddressSanitizer" in diagnostics or "runtime error:" in diagnostics:
                    result.update(passed=False, runtime_log=diagnostics, shutdown_code=server.returncode)
            return result


def main():
    parser = argparse.ArgumentParser(description="Compare queued interactive history searches across SQLite ordering barriers")
    for name in ("zig", "cpp", "probe", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--admission", action="store_true")
    modes.add_argument("--capacity", action="store_true")
    arguments = parser.parse_args()
    binaries = {name: getattr(arguments, name).resolve() for name in ("zig", "cpp", "probe")}
    mode = "capacity" if arguments.capacity else "admission" if arguments.admission else ""
    report = {"acceptance": "functional_only", "mode": mode or "supersession", "binaries": {name: fingerprint(binary) for name, binary in binaries.items()}, "cases": {}}
    for language in ("zig", "cpp"):
        report["cases"][language] = check(binaries[language], binaries["probe"], mode)
        print(language, report["cases"][language], flush=True)
    report["passed"] = all(case["passed"] for case in report["cases"].values()) and report["cases"]["zig"] == report["cases"]["cpp"]
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(report, indent=2) + "\n")
    return int(not report["passed"])


if __name__ == "__main__":
    raise SystemExit(main())
