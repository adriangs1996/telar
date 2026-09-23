#!/usr/bin/env python3
"""Paired, alternated timing of telar-dod-probe terminal workloads.

usage: probe_pair.py BASELINE_PREFIX CANDIDATE_PREFIX PAIRS [MODE ...]

Each prefix is a `zig build build-dod-probe --prefix` directory. Runs
alternate order every pair (A,B then B,A) so drift hits both sides. Prints the
median of per-run means and the median paired ratio with the win count.
"""
import json, os, statistics, subprocess, sys

DEFAULT_MODES = ["retained", "sparse", "full", "two_all_active", "cursor", "selection"]


def run(prefix, mode):
    env = dict(os.environ, DOD_TERMINAL_ONLY="1", DOD_MODE=mode,
               DOD_SAMPLES="1000" if mode == "full" else "3000", DOD_WARMUP="300")
    out = subprocess.run([os.path.join(prefix, "bin", "telar-dod-probe")], env=env,
                         capture_output=True, text=True, check=True).stdout
    result = {}
    for line in out.splitlines():
        if '"workload"' in line:
            record = json.loads(line)
            result[record["name"]] = record["elapsed_ns"] / record["iterations"] / 1000
    return result


def main():
    baseline, candidate, pairs = sys.argv[1], sys.argv[2], int(sys.argv[3])
    modes = sys.argv[4:] or DEFAULT_MODES
    samples = {}
    for index in range(pairs):
        for mode in modes:
            for prefix in ([baseline, candidate] if index % 2 == 0 else [candidate, baseline]):
                for name, value in run(prefix, mode).items():
                    samples.setdefault(name, {}).setdefault(prefix, []).append(value)
    print(f"{'case':34}{'A µs':>10}{'B µs':>10}  {'paired':>8}  wins")
    for name, by_prefix in samples.items():
        ratios = [b / a - 1 for a, b in zip(by_prefix[baseline], by_prefix[candidate])]
        print(f"{name:34}{statistics.median(by_prefix[baseline]):10.2f}"
              f"{statistics.median(by_prefix[candidate]):10.2f}  "
              f"{statistics.median(ratios) * 100:+7.1f}%  {sum(r < 0 for r in ratios)}/{len(ratios)}")


main()
