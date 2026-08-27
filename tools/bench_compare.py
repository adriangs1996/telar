#!/usr/bin/env python3
"""Compare two JSON Lines runs produced by `zig build bench -- --json`."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


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
            match record.get("type"):
                case "metadata":
                    metadata = record
                case "benchmark":
                    benchmarks[record["name"]] = record
    if metadata is None:
        raise ValueError(f"{path}: missing metadata record")
    if not benchmarks:
        raise ValueError(f"{path}: no benchmark records")
    return metadata, benchmarks


def validate_metadata(baseline: dict[str, Any], candidate: dict[str, Any]) -> None:
    fields = (
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
    mismatches = [
        f"{field}: {baseline.get(field)!r} != {candidate.get(field)!r}"
        for field in fields
        if baseline.get(field) != candidate.get(field)
    ]
    if mismatches:
        raise ValueError("incompatible benchmark runs: " + ", ".join(mismatches))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument(
        "--fail-above",
        type=float,
        metavar="PERCENT",
        help="exit with status 1 if any median regresses by more than PERCENT",
    )
    parser.add_argument(
        "--fail-payload-above",
        type=float,
        metavar="PERCENT",
        help="exit with status 1 if any payload grows by more than PERCENT",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        baseline_meta, baseline = load(args.baseline)
        candidate_meta, candidate = load(args.candidate)
        validate_metadata(baseline_meta, candidate_meta)
    except (OSError, KeyError, TypeError, ValueError) as error:
        print(error, file=sys.stderr)
        return 2

    missing = baseline.keys() ^ candidate.keys()
    if missing:
        print("benchmark sets differ: " + ", ".join(sorted(missing)), file=sys.stderr)
        return 2

    print(f"{'benchmark':38} {'baseline':>12} {'candidate':>12} {'change':>10} {'payload':>17}")
    regressed = False
    for name, old in baseline.items():
        old_ns = int(old["median_ns_per_op"])
        new_ns = int(candidate[name]["median_ns_per_op"])
        change = 0.0 if old_ns == 0 else (new_ns / old_ns - 1.0) * 100.0
        old_bytes = int(old.get("payload_bytes_per_op", 0))
        new_bytes = int(candidate[name].get("payload_bytes_per_op", 0))
        payload = "-" if old_bytes == 0 and new_bytes == 0 else f"{old_bytes} -> {new_bytes} B"
        print(
            f"{name:38} {old_ns:>9} ns {new_ns:>9} ns "
            f"{change:>+9.2f}% {payload:>17}"
        )
        if args.fail_above is not None and change > args.fail_above:
            regressed = True
        if args.fail_payload_above is not None and old_bytes != 0:
            payload_change = (new_bytes / old_bytes - 1.0) * 100.0
            if payload_change > args.fail_payload_above:
                regressed = True
    return 1 if regressed else 0


if __name__ == "__main__":
    raise SystemExit(main())
