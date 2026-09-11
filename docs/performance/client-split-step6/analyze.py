#!/usr/bin/env python3
"""Summarize committed probe data without overriding the noisy-host verdict."""
import gzip
import json
from pathlib import Path
import statistics
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[2] / "tools"))
import perf_gate


def main():
    result = {"verdict": "no verdict: benchmark host is noisy", "micro": {}}
    for target in ["40ms", "100ms"]:
        runs = [perf_gate.load(p) for p in sorted((HERE / "micro" / target).glob("*.jsonl"))]
        perf_gate.validate_runs(runs)
        payloads = {name: sorted({cases[name]["payload_bytes_per_op"] for _, cases in runs})
                    for name in runs[0][1]}
        result["micro"][target] = {
            "runs": len(runs), "cases": len(payloads),
            "identical_payloads": all(len(values) == 1 for values in payloads.values()),
            "payload_bytes_per_op": payloads,
        }
    probes = json.loads((HERE / "e2e.json").read_text())
    result["e2e"] = {"runs": len(probes), "latency": {},
                     "all_shutdowns_clean": all(r["shutdown"]["cleanup_complete"] for r in probes)}
    for case in ["echo", "load"]:
        result["e2e"]["latency"][case] = {}
        for label in ["baseline", "candidate"]:
            rows = [r for r in probes if r["case"] == case and r["version"] == label]
            result["e2e"]["latency"][case][label] = {
                "samples": sum(len(r["raw_us"]) for r in rows),
                "timeouts": sum(r["timeouts"] for r in rows),
                "median_of_run_percentiles_us": {
                    key: statistics.median(r[key] for r in rows)
                    for key in ["p50_us", "p95_us", "p99_us"]
                },
            }
    telemetry = json.loads(gzip.decompress((HERE / "telemetry.json.gz").read_bytes()))
    result["telemetry"] = {}
    for case, roles in telemetry.items():
        result["telemetry"][case] = {}
        for role, rows in roles.items():
            window = [r for r in rows if r["ts_ms"] - rows[0]["ts_ms"] >= 6000]
            result["telemetry"][case][role] = {
                "sampled_peak_rss_bytes": max(r["rss_bytes"] for r in rows),
                "sampled_peak_heap_bytes": max(r["heap_live_bytes"] for r in rows),
                "steady_samples": len(window),
                "interactive_alloc_delta_after_6s": (
                    window[-1]["interactive_allocs"] - window[0]["interactive_allocs"]
                    if len(window) >= 2 else None
                ),
                "max_counters": {key: max(r[key] for r in rows)
                                 for key in rows[0] if any(part in key for part in ["dropped", "resync", "high_water"])},
            }
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
