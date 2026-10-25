#!/usr/bin/env python3
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import time


def check_case(runtime, probe, workload, configuration, event_name):
    with tempfile.TemporaryDirectory(prefix="telar-trace-", dir="/tmp") as directory:
        root = Path(directory)
        socket = root / "runtime.sock"
        trace = root / "trace.json"
        config = root / "config.lua"
        config.write_text(configuration)
        environment = {key: value for key, value in os.environ.items() if not key.startswith("TELAR_")}
        environment.update({name: str(root / name.lower()) for name in
                            ("XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME")})
        command = [str(runtime), "--socket", str(socket), "--trace", str(trace), "--config", str(config)]
        with (root / "server.log").open("w+") as log:
            server = subprocess.Popen(command, env=environment, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 15
                while not socket.exists():
                    if server.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError("Debug runtime did not start")
                    time.sleep(0.01)

                result = subprocess.run([str(probe), str(socket), workload, "1", str(root / "oracle.bin")],
                                        env=environment, capture_output=True, text=True, timeout=30)
                if result.returncode != 0:
                    raise RuntimeError(result.stderr.strip())
            finally:
                server.terminate()
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()

            log.flush()
            log.seek(0)
            if server.returncode != 0:
                raise RuntimeError(f"Debug runtime failed: {log.read()}")

        events = json.loads(trace.read_text())
        main_threads = {event["tid"] for event in events if event["name"] == "runtime.run"}
        names = (event_name,) if isinstance(event_name, str) else event_name
        worker_events = [event for event in events if event["name"] in names]
        assert len(main_threads) == 1, "Missing runtime thread scope"
        for name in names:
            assert any(event["name"] == name for event in worker_events), f"Missing {name} trace"
        assert all(event["tid"] not in main_threads for event in worker_events), "Background work ran on the runtime thread"
        assert all(event["dur"] >= 0 for event in worker_events)
        dropped = sum(event.get("args", {}).get("dropped_records", 0) for event in events)
        assert dropped == 0, "Trace dropped events"
        assert stat.S_IMODE(trace.stat().st_mode) == 0o600, "Trace is not private"
        return {"event": event_name, "count": len(worker_events), "events": len(events),
                "threads": len({event["tid"] for event in events if "tid" in event}),
                "dropped_records": dropped, "worker_thread_verified": True}


def main():
    parser = argparse.ArgumentParser(description="Check Debug tracing for agent background work")
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--description-probe", type=Path, required=True)
    parser.add_argument("--session-file-probe", type=Path, required=True)
    parser.add_argument("--reporter-probe", type=Path)
    parser.add_argument("--path-probe", type=Path)
    parser.add_argument("--services-probe", type=Path)
    parser.add_argument("--graphics-probe", type=Path)
    parser.add_argument("--configuration", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    runtime = arguments.runtime.resolve()
    report = {"checked_at": datetime.now(timezone.utc).isoformat(), "runtime": str(runtime),
              "sha256": hashlib.sha256(runtime.read_bytes()).hexdigest(), "cases": {}}
    configuration = arguments.configuration.read_text()
    report["cases"]["description"] = check_case(runtime, arguments.description_probe.resolve(), "description-success",
                                                 configuration, "agents.generateDescription")
    report["cases"]["session_file"] = check_case(runtime, arguments.session_file_probe.resolve(), "session-cursor",
                                                  configuration, "agents.readSessionTitle")
    if arguments.reporter_probe:
        report["cases"]["descent"] = check_case(runtime, arguments.reporter_probe.resolve(), "reporter-replace-state",
                                                  configuration, ("agents.verifyDescent", "process.observe", "observation.replay"))
    if arguments.path_probe:
        report["cases"]["paths"] = check_case(runtime, arguments.path_probe.resolve(), "paths-large",
                                              configuration, ("paths.build", "paths.query"))
    if arguments.services_probe:
        report["cases"]["workspace_git"] = check_case(runtime, arguments.services_probe.resolve(), "worktrees",
                                                      configuration, ("workspaces.gitProbe", "worktrees.gitProbe", "worktrees.detect"))
    if arguments.graphics_probe:
        report["cases"]["graphics"] = check_case(runtime, arguments.graphics_probe.resolve(), "graphics-file",
                                                 configuration, ("media.worker", "media.process", "media.terminal.feed", "media.prepareTransfers", "media.freezeImage"))
        report["cases"]["graphics_shared"] = check_case(runtime, arguments.graphics_probe.resolve(), "graphics-file-shared",
                                                        configuration, ("media.worker", "media.prepareShared", "media.freezeImage"))
        report["cases"]["graphics_atomic"] = check_case(runtime, arguments.graphics_probe.resolve(), "graphics-shm-atomic-shared",
                                                        configuration, ("media.worker", "media.process", "media.loadAtomicFrame"))
    arguments.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report["cases"], indent=2))


if __name__ == "__main__":
    main()
