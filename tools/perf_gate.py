#!/usr/bin/env python3
"""Compare repeated Telar benchmark runs using percentile-specific gates."""

from __future__ import annotations

import argparse
import glob
import json
import statistics
import sys
from pathlib import Path
from typing import Any


TIMINGS = {
    "median_ns_per_op": "p50",
    "p95_ns_per_op": "p95",
    "p99_ns_per_op": "p99",
}
METADATA_FIELDS = (
    "zig",
    "mode",
    "arch",
    "cpu",
    "os",
    "cols",
    "rows",
    "samples",
    "sample_target_ns",
)


def expand(patterns: list[str]) -> list[Path]:
    paths: list[Path] = []
    for pattern in patterns:
        matches = [Path(value) for value in glob.glob(pattern)]
        paths.extend(matches or [Path(pattern)])
    return paths


def load(path: Path) -> tuple[dict[str, Any], dict[str, dict[str, Any]]]:
    metadata: dict[str, Any] | None = None
    benchmarks: dict[str, dict[str, Any]] = {}
    with path.open(encoding="utf-8") as stream:
        for line_number, line in enumerate(stream, 1):
            if not line.strip():
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError as error:
                raise ValueError(f"{path}:{line_number}: invalid JSON: {error}") from error
            if record.get("type") == "metadata":
                metadata = record
            elif record.get("type") == "benchmark":
                benchmarks[record["name"]] = record
    if metadata is None:
        raise ValueError(f"{path}: missing metadata record")
    if not benchmarks:
        raise ValueError(f"{path}: no benchmark records")
    return metadata, benchmarks


def validate_runs(
    runs: list[tuple[dict[str, Any], dict[str, dict[str, Any]]]],
) -> None:
    reference_meta, reference_cases = runs[0]
    for metadata, cases in runs[1:]:
        mismatches = [
            field
            for field in METADATA_FIELDS
            if metadata.get(field) != reference_meta.get(field)
        ]
        if mismatches:
            raise ValueError("incompatible benchmark metadata: " + ", ".join(mismatches))
        missing = reference_cases.keys() ^ cases.keys()
        if missing:
            raise ValueError("benchmark sets differ: " + ", ".join(sorted(missing)))


def aggregate(
    runs: list[tuple[dict[str, Any], dict[str, dict[str, Any]]]],
) -> dict[str, dict[str, float]]:
    names = runs[0][1].keys()
    return {
        name: {
            field: statistics.median(
                float(run_cases[name].get(field, 0)) for _, run_cases in runs
            )
            for field in (*TIMINGS, "payload_bytes_per_op")
        }
        for name in names
    }


def noisy(
    runs: list[tuple[dict[str, Any], dict[str, dict[str, Any]]]],
    thresholds: dict[str, float],
) -> list[str]:
    noisy_cases: list[str] = []
    for name in runs[0][1]:
        for field, label in TIMINGS.items():
            values = [float(cases[name][field]) for _, cases in runs]
            low = min(values)
            spread = 0.0 if low == 0 else (max(values) / low - 1.0) * 100.0
            if spread > thresholds[label]:
                noisy_cases.append(f"{name}.{label} ({spread:.2f}%)")
    return noisy_cases


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", nargs="+", required=True)
    parser.add_argument("--candidate", nargs="+", required=True)
    parser.add_argument("--p50-percent", type=float, default=5.0)
    parser.add_argument("--p95-percent", type=float, default=8.0)
    parser.add_argument("--p99-percent", type=float, default=10.0)
    parser.add_argument("--payload-byte-delta", type=int, default=0)
    parser.add_argument("--allow-noisy", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        baseline_runs = [load(path) for path in expand(args.baseline)]
        candidate_runs = [load(path) for path in expand(args.candidate)]
        if not baseline_runs or not candidate_runs:
            raise ValueError("baseline and candidate require at least one run")
        all_runs = baseline_runs + candidate_runs
        validate_runs(all_runs)
    except (OSError, KeyError, TypeError, ValueError) as error:
        print(error, file=sys.stderr)
        return 2

    thresholds = {
        "p50": args.p50_percent,
        "p95": args.p95_percent,
        "p99": args.p99_percent,
    }
    noisy_cases = noisy(baseline_runs, thresholds) + noisy(candidate_runs, thresholds)
    if noisy_cases and not args.allow_noisy:
        print("no verdict: benchmark host is noisy", file=sys.stderr)
        for case in noisy_cases:
            print(f"  {case}", file=sys.stderr)
        return 2

    baseline = aggregate(baseline_runs)
    candidate = aggregate(candidate_runs)
    failed = False
    print(f"{'benchmark':38} {'p50':>9} {'p95':>9} {'p99':>9} {'payload':>14}")
    for name, old in baseline.items():
        changes: dict[str, float] = {}
        for field, label in TIMINGS.items():
            changes[label] = 0.0 if old[field] == 0 else (
                candidate[name][field] / old[field] - 1.0
            ) * 100.0
            if changes[label] > thresholds[label]:
                failed = True
        payload_delta = int(candidate[name]["payload_bytes_per_op"] - old["payload_bytes_per_op"])
        if abs(payload_delta) > args.payload_byte_delta:
            failed = True
        print(
            f"{name:38} {changes['p50']:>+8.2f}% {changes['p95']:>+8.2f}% "
            f"{changes['p99']:>+8.2f}% {payload_delta:>+10} B"
        )
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
