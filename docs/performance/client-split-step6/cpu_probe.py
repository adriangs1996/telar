#!/usr/bin/env python3
"""Reproduce the local CPU probe; this is not a performance acceptance gate."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "tools"))
import load_latency
import perf_e2e


def seconds(value):
    result = 0.0
    for part in value.split(":"):
        result = result * 60 + float(part)
    return result


def usage(pids):
    output = subprocess.check_output(
        ["ps", "-p", ",".join(map(str, pids)), "-o", "pid=,time=,rss="], text=True
    )
    return {
        int(pid): (seconds(cpu), int(rss) * 1024)
        for pid, cpu, rss in (row.split() for row in output.splitlines())
    }


def measure(binary, directory, case):
    env = perf_e2e.isolated_environment(directory)
    master, slave = load_latency.pty.openpty()
    load_latency.set_winsize(slave, 70, 240)
    proc = subprocess.Popen(
        [binary, "--no-config"], stdin=slave, stdout=slave, stderr=slave, env=env,
        cwd=directory, preexec_fn=load_latency.become_session_leader, close_fds=True,
    )
    os.close(slave)
    try:
        load_latency.drain(master, 3)
        if case == "load":
            load_latency.open_telar_floods(master, 2)
        load_latency.drain(master, 4)
        runtime = perf_e2e.runtime_pids(env["TELAR_SOCKET_PATH"])
        assert len(runtime) == 1
        pids = [runtime[0], proc.pid]
        before = usage(pids)
        peak = {pid: before[pid][1] for pid in pids}
        start = time.perf_counter()
        for _ in range(10):
            load_latency.drain(master, 1)
            current = usage(pids)
            for pid in pids:
                peak[pid] = max(peak[pid], current[pid][1])
        elapsed = time.perf_counter() - start
        return {
            "seconds": elapsed,
            **{role: {
                "cpu_percent": (current[pid][0] - before[pid][0]) / elapsed * 100,
                "sampled_peak_rss_bytes": peak[pid],
            } for role, pid in zip(["runtime", "client"], pids)},
        }
    finally:
        load_latency.terminate(proc)
        os.close(master)
        shutdown = perf_e2e.stop_runtime(binary, env)
        (directory / "shutdown.json").write_text(json.dumps(shutdown, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--repetitions", type=int, default=5)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir()
    binaries = {name: str(getattr(args, name).resolve()) for name in ["baseline", "candidate"]}
    results = []
    for run in range(args.repetitions):
        for case in ["idle", "load"]:
            order = ["baseline", "candidate"] if run % 2 == 0 else ["candidate", "baseline"]
            for label in order:
                directory = output / f"{label}-{case}-{run}"
                result = measure(binaries[label], directory, case)
                result.update(version=label, case=case, run=run,
                              shutdown=json.loads((directory / "shutdown.json").read_text()))
                results.append(result)
                (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
                print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
