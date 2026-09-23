#!/usr/bin/env python3
"""Paired, alternated comparison of telar-benchmarks cases.

usage: bench_pair.py BASELINE_PREFIX CANDIDATE_PREFIX PAIRS FILTER

Each prefix is a `zig build build-bench --prefix` directory. FILTER is passed
to `--filter`. Prints median ns/op per side, the median paired ratio, wins and
the minimum ns/op per side (the minimum is the least noisy on a busy host).
"""
import json, os, statistics, subprocess, sys


def run(prefix, pattern):
    out = subprocess.run([os.path.join(prefix, "bin", "telar-benchmarks"), "--samples", "12",
                          "--json", "--filter", pattern], capture_output=True, text=True, check=True).stdout
    result = {}
    for line in out.splitlines():
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if record.get("type") == "benchmark":
            result[record["name"]] = (record["median_ns_per_op"], record["min_ns_per_op"])
    return result


def main():
    baseline, candidate, pairs, pattern = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
    samples = {}
    for index in range(pairs):
        for prefix in ([baseline, candidate] if index % 2 == 0 else [candidate, baseline]):
            for name, value in run(prefix, pattern).items():
                samples.setdefault(name, {}).setdefault(prefix, []).append(value)
    print(f"{'case':44}{'A med':>10}{'B med':>10}{'paired':>10}{'wins':>6}{'A min':>9}{'B min':>9}")
    for name, by_prefix in samples.items():
        if baseline not in by_prefix or candidate not in by_prefix:
            print(f"{name:44} only in {'baseline' if baseline in by_prefix else 'candidate'}")
            continue
        a, b = by_prefix[baseline], by_prefix[candidate]
        ratios = [y[0] / x[0] - 1 for x, y in zip(a, b)]
        print(f"{name:44}{statistics.median(v[0] for v in a):10.0f}{statistics.median(v[0] for v in b):10.0f}"
              f"{statistics.median(ratios) * 100:+9.1f}%{sum(r < 0 for r in ratios):>4}/{len(ratios)}"
              f"{min(v[1] for v in a):9.0f}{min(v[1] for v in b):9.0f}")


main()
