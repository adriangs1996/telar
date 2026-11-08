import argparse
import json
import os
from pathlib import Path
import resource
import statistics
import subprocess


def measure(executable):
    environment = dict(os.environ, QT_QPA_PLATFORM="offscreen")
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    completed = subprocess.run(
        [str(executable)],
        check=True,
        capture_output=True,
        text=True,
        env=environment,
    )
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    result = json.loads(completed.stdout)
    result["process_cpu_ns"] = round(
        (after.ru_utime + after.ru_stime - before.ru_utime - before.ru_stime)
        * 1_000_000_000
    )
    return result


def compare(baseline, candidate, pair_count):
    pairs = []
    for pair_index in range(pair_count):
        order = ("baseline", "candidate") if pair_index % 2 == 0 else ("candidate", "baseline")
        results = {}
        for variant in order:
            results[variant] = measure(baseline if variant == "baseline" else candidate)

        for field in ("sidebar_visible", "callback"):
            if results["baseline"][field] != results["candidate"][field]:
                raise RuntimeError(f"Configuration oracle mismatch for {field}")

        pairs.append(results)

    metrics = {}
    for field in ("call_ns", "heartbeat_ns", "completion_ns", "process_cpu_ns"):
        previous = [pair["baseline"][field] for pair in pairs]
        current = [pair["candidate"][field] for pair in pairs]
        metrics[field] = {
            "baseline_median": statistics.median(previous),
            "candidate_median": statistics.median(current),
            "candidate_wins": sum(new < old for old, new in zip(previous, current)),
        }

    return {
        "baseline": str(baseline),
        "candidate": str(candidate),
        "pair_count": pair_count,
        "oracle": "sidebar preference and callback action matched in every pair",
        "metrics": metrics,
        "pairs": pairs,
    }


def main():
    parser = argparse.ArgumentParser(description="Compare Release configuration reload probes in alternating pairs")
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--pairs", type=int, default=7)
    parser.add_argument("--output", type=Path)
    options = parser.parse_args()
    if options.pairs < 1:
        parser.error("--pairs must be positive")

    result = compare(options.baseline.resolve(), options.candidate.resolve(), options.pairs)
    rendered = json.dumps(result, indent=2) + "\n"
    if options.output is not None:
        options.output.write_text(rendered)

    print(rendered, end="")


if __name__ == "__main__":
    main()
