#!/usr/bin/env python3
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import stat
import tempfile

from check_hook_cli import run_case


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    runtime = arguments.runtime.resolve()
    with tempfile.TemporaryDirectory(prefix="telar-hook-trace-", dir="/tmp") as directory:
        root = Path(directory)
        trace = root / "hook.json"
        result, _ = run_case(runtime, root, {"provider": "claude", "input": {"hook_event_name": "SessionStart", "cwd": "/tmp", "session_title": "Trace fixture"},
                                           "environment": {"TELAR_HOOK_TRACE": str(trace)}})
        assert result["status"] == 0 and len(result["frames"]) == 4
        events = json.loads(trace.read_text())
        counts = {name: sum(event["name"] == name for event in events) for name in ("hooks.readInput", "hooks.mapReports", "hooks.sendReport")}
        assert counts == {"hooks.readInput": 1, "hooks.mapReports": 1, "hooks.sendReport": 3}
        dropped = sum(event.get("args", {}).get("dropped_records", 0) for event in events)
        assert dropped == 0
        assert stat.S_IMODE(trace.stat().st_mode) == 0o600
        report = {"checked_at": datetime.now(timezone.utc).isoformat(), "runtime": str(runtime), "sha256": hashlib.sha256(runtime.read_bytes()).hexdigest(),
                  "counts": counts, "events": len(events), "dropped_records": dropped, "mode": "0600", "passed": True}
    arguments.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
