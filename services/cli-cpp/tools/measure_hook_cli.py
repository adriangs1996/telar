#!/usr/bin/env python3
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import tempfile

from check_hook_cli import run_case


def workloads():
    return {
        "lifecycle": {"provider": "claude", "input": {"hook_event_name": "SessionStart", "session_title": "Fixture", "cwd": "/tmp"}},
        "command": {"provider": "claude", "input": {"hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_use_id": "fixture", "tool_input": {"command": "printf " + "x" * 2048}, "cwd": "/tmp"}},
        "plan": {"provider": "codex", "input": {"hook_event_name": "PostToolUse", "tool_name": "update_plan", "tool_input": {"plan": [{"step": f"Step {index}", "status": "completed" if index < 64 else "pending"} for index in range(128)]}}},
        "large_input": {"provider": "claude", "input": {"hook_event_name": "PostToolUse", "tool_name": "Write", "tool_input": {"file_path": "fixture.txt", "content": "x" * (512 * 1024)}}},
    }


def run(binary, root, fixture, iterations):
    times = []
    digest = None
    for _ in range(iterations):
        result, elapsed = run_case(binary, root, fixture)
        if result["status"] != 0 or not result["frames"]:
            raise RuntimeError("Hook benchmark did not produce reports")
        current = hashlib.sha256(json.dumps(result, sort_keys=True).encode()).hexdigest()
        if digest is not None and current != digest:
            raise RuntimeError("Hook behavior changed within the measurement")
        digest = current
        times.append(elapsed)
    return {"iterations": iterations, "elapsed_ns": sum(times), "ns_per_iteration": sum(times) / iterations, "samples_ns": times, "digest": digest}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--zig", type=Path, required=True)
    parser.add_argument("--cpp", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--iterations", type=int, default=16)
    arguments = parser.parse_args()
    report = {"measured_at": datetime.now(timezone.utc).isoformat(), "platform": platform.platform(), "architecture": platform.machine(), "load": os.getloadavg(),
              "scope": "Hook process startup, input mapping and IPC against the same acknowledging fixture server", "binaries": {}, "cases": {}}
    for implementation in ("zig", "cpp"):
        binary = getattr(arguments, implementation).resolve()
        report["binaries"][implementation] = {"path": str(binary), "sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}
    with tempfile.TemporaryDirectory(prefix="telar-hook-timing-", dir="/tmp") as directory:
        root = Path(directory)
        for name, fixture in workloads().items():
            for implementation in ("zig", "cpp"):
                run(getattr(arguments, implementation).resolve(), root, fixture, 2)
            pairs = []
            for pair in range(7):
                results = {}
                for implementation in (("zig", "cpp") if pair % 2 == 0 else ("cpp", "zig")):
                    results[implementation] = run(getattr(arguments, implementation).resolve(), root, fixture, arguments.iterations)
                if results["zig"]["digest"] != results["cpp"]["digest"]:
                    raise RuntimeError(f"{name}: hook output mismatch")
                results["ratio"] = results["cpp"]["ns_per_iteration"] / results["zig"]["ns_per_iteration"]
                pairs.append(results)
                print(f"{name} pair {pair + 1}: {results['ratio']:.4f}", flush=True)
                report["cases"][name] = {"pairs": pairs, "wins": sum(item["ratio"] <= 1 for item in pairs), "median_ratio": statistics.median(item["ratio"] for item in pairs)}
                arguments.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
