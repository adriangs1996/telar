#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import time


def fingerprint(path):
    return {"path": str(path.resolve()), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def prepare_failure(root, scenario):
    database = root / "history.db"
    if scenario == "directory":
        database.mkdir(mode=0o700)
    elif scenario == "parent-file":
        database.write_bytes(b"not a directory")
        database.chmod(0o600)
        return database / "nested.db"
    elif scenario == "incompatible-schema":
        with sqlite3.connect(database) as connection:
            connection.execute("CREATE TABLE command(incompatible INTEGER)")
        database.chmod(0o600)
    else:
        database.write_bytes(b"not a SQLite database" * 128)
        database.chmod(0o600)
    return database


def run(arguments, binary, root, database, available):
    endpoint = root / "runtime.sock"
    endpoint.unlink(missing_ok=True)
    environment = {key: value for key, value in os.environ.items() if not key.startswith("TELAR_")}
    for name, directory in {"HOME": "home", "XDG_CONFIG_HOME": "config", "XDG_DATA_HOME": "data", "XDG_STATE_HOME": "state", "XDG_CACHE_HOME": "cache"}.items():
        path = root / directory
        path.mkdir(exist_ok=True)
        environment[name] = str(path)
    environment.update(SHELL="/bin/sh", TERM="xterm-256color")
    configuration = root / "runtime.lua"
    configuration.write_text('return {api_version=2,runtime={history={path=' + json.dumps(str(database)) + '},proxy={enabled=false},session={persist=false}}}\n')
    mode = "history" if available else "history-unavailable"
    with (root / "server.log").open("w+") as log:
        server = subprocess.Popen([str(binary), "server", "--socket", str(endpoint), "--config", str(configuration)], env=environment, stdout=log, stderr=log)
        try:
            if available is None:
                assert server.wait(timeout=10) == 1 and not endpoint.exists(), "Invalid path did not prevent startup"
                return {"startup_rejected": True}

            deadline = time.monotonic() + 20
            while not endpoint.exists():
                if server.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("Runtime did not start")
                time.sleep(0.01)

            dump = root / "history.bin"
            subprocess.run([str(arguments.probe), str(endpoint), mode, "1", str(dump)], env=environment, check=True, capture_output=True, timeout=30)
            screen = root / "screen.bin"
            subprocess.run([str(arguments.terminal_probe), str(endpoint), "sparse", "2", str(screen)], env=environment, check=True, capture_output=True, timeout=30)
            samples = []
            if arguments.diagnostics and binary == arguments.cpp:
                log_path = root / f"runtime.sock.runtime-{server.pid}.log"
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    samples = [json.loads(line) for line in log_path.read_text().split("\n")[:-1]] if log_path.exists() else []
                    if samples and samples[-1]["sqlite_queries"] >= (1 if available else 2):
                        break
                    time.sleep(0.02)
                assert samples, "No history diagnostics"
                metrics = samples[-1]
                assert metrics["history_available"] == int(available), metrics
                assert metrics["sqlite_open_failures"] == int(not available), metrics
                assert metrics["sqlite_writes"] > 0 and metrics["history_queue_high_water"] > 0, metrics
                assert metrics["history_queries"] > 0 and metrics["history_query_failures"] == 0, metrics
                assert metrics["sqlite_query_failures"] == (0 if available else 2), metrics
                if available:
                    assert metrics["sqlite_write_failures"] == 0, metrics
                else:
                    assert metrics["sqlite_write_failures"] > 0, metrics

            return {"history_sha256": hashlib.sha256(dump.read_bytes()).hexdigest(), "screen_sha256": hashlib.sha256(screen.read_bytes()).hexdigest(), "samples": samples}
        except Exception as error:
            log.flush()
            log.seek(0)
            probe_error = error.stderr.decode(errors="replace") if isinstance(error, subprocess.CalledProcessError) else ""
            raise RuntimeError(f"{mode}: {error}\n{probe_error}\n{log.read()}") from error
        finally:
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
            allowed_exits = (1,) if available is None else (0, -15) if binary == arguments.zig else (0,)
            if server.returncode not in allowed_exits or "ERROR: AddressSanitizer" in diagnostics or "runtime error:" in diagnostics:
                raise RuntimeError(f"Runtime exited with {server.returncode}\n{diagnostics}")


def main():
    parser = argparse.ArgumentParser(description="Check degraded history and recovery against the Zig runtime")
    for name in ("zig", "cpp", "probe", "terminal-probe", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--diagnostics", action="store_true")
    arguments = parser.parse_args()
    for name in ("zig", "cpp", "probe", "terminal_probe"):
        setattr(arguments, name, getattr(arguments, name).resolve())
    report = {"binaries": {name: fingerprint(getattr(arguments, name)) for name in ("zig", "cpp", "probe", "terminal_probe")}, "cases": []}
    try:
        for scenario in ("corrupt", "directory", "parent-file", "incompatible-schema"):
            case = {"scenario": scenario, "implementations": {}}
            report["cases"].append(case)
            for language in ("zig", "cpp"):
                with tempfile.TemporaryDirectory(prefix="telar-history-", dir="/tmp") as temporary:
                    root = Path(temporary)
                    database = prepare_failure(root, scenario)
                    degraded = run(arguments, getattr(arguments, language), root, database, None if scenario in ("directory", "parent-file") else False)
                    for path in root.glob("history.db*"):
                        if path.is_dir():
                            shutil.rmtree(path)
                        else:
                            path.unlink()
                    database.parent.mkdir(exist_ok=True)
                    recovered = run(arguments, getattr(arguments, language), root, database, True)
                    case["implementations"][language] = {"degraded": degraded, "recovered": recovered}
            for phase in ("degraded", "recovered"):
                if phase == "degraded" and scenario in ("directory", "parent-file"):
                    assert case["implementations"]["zig"][phase] == case["implementations"]["cpp"][phase]
                    continue
                for name in ("history_sha256", "screen_sha256"):
                    assert case["implementations"]["zig"][phase][name] == case["implementations"]["cpp"][phase][name], (scenario, phase, name)
            print(scenario + ": degraded and recovered replies match", flush=True)
        report["passed"] = True
    except Exception as error:
        report.update(passed=False, error=str(error))
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(report, indent=2) + "\n")
    if not report["passed"]:
        print(report["error"], flush=True)
    return int(not report["passed"])


if __name__ == "__main__":
    raise SystemExit(main())
