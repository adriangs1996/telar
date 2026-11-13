#!/usr/bin/env python3
"""Paired before/after Claude hook startup with one stdin event and real IPC."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import tempfile

from check_hook_cli import run_case


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--before", type=Path, required=True)
    parser.add_argument("--after", type=Path, required=True)
    parser.add_argument("--scratch", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--iterations", type=int, default=16)
    arguments = parser.parse_args()
    report = {"scope": "Claude SessionStart, process startup, one JSON stdin event and acknowledging private socket",
              "load": os.getloadavg(), "pairs": [], "binaries": {}}
    for name in ("before", "after"):
        binary = getattr(arguments, name).resolve()
        report["binaries"][name] = {"path": str(binary), "sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}
    with tempfile.TemporaryDirectory(prefix="hook-er-", dir=arguments.scratch) as directory:
        root = Path(directory)
        for key in tuple(os.environ):
            if key.startswith("TELAR_"):
                os.environ.pop(key)
        for key in ("HOME", "XDG_RUNTIME_DIR", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "TMPDIR"):
            os.environ[key] = str(root)
        fixture = {"provider": "claude", "input": {"hook_event_name": "SessionStart", "session_title": "Fixture", "cwd": str(root)}}
        expected = None
        samples = {"before": [], "after": []}
        for pair in range(7):
            current = {}
            for name in (("before", "after") if pair % 2 == 0 else ("after", "before")):
                block = []
                for _ in range(arguments.iterations):
                    result, elapsed = run_case(getattr(arguments, name).resolve(), root, fixture)
                    assert result["status"] == 0 and result["frames"]
                    if expected is None:
                        expected = result
                    assert result == expected
                    block.append(elapsed)
                samples[name].extend(block)
                current[name] = statistics.median(block)
            current["ratio"] = current["after"] / current["before"]
            report["pairs"].append(current)
        report["samples_ns"] = samples
        report["p50_ms"] = {name: statistics.median(values) / 1e6 for name, values in samples.items()}
        report["median_pair_ratio"] = statistics.median(pair["ratio"] for pair in report["pairs"])
        arguments.output.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps({key: report[key] for key in ("p50_ms", "median_pair_ratio")}))


if __name__ == "__main__":
    main()
