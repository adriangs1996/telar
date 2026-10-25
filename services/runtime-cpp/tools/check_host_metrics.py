#!/usr/bin/env python3
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform

from compare_runtimes import run_probe


def main():
    parser = argparse.ArgumentParser(description="Check host metrics cadence, projection and subscription delivery")
    for name in ("zig", "cpp", "probe", "output"):
        parser.add_argument(f"--{name}", type=Path, required=True)
    arguments = parser.parse_args()
    report = {
        "measured_at": datetime.now(timezone.utc).isoformat(),
        "platform": platform.platform(),
        "binaries": {
            name: {"path": str(path.resolve()), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
            for name, path in (("zig", arguments.zig), ("cpp", arguments.cpp), ("probe", arguments.probe))
        },
        "normalization": "Memory used and battery charge are volatile across runs. CPU count, total memory, battery presence, initial CPU zero and revision must match. Each run checks unchanged delivery to a second subscriber.",
    }
    dumps = {}
    for implementation in ("zig", "cpp"):
        report[implementation], dumps[implementation] = run_probe(
            getattr(arguments, implementation).resolve(), implementation,
            arguments.probe.resolve(), "metrics", 1,
        )
    report["equivalent"] = dumps["zig"] == dumps["cpp"]
    arguments.output.write_text(json.dumps(report, indent=2) + "\n")
    if not report["equivalent"]:
        raise SystemExit("Host metrics protocol differs")
    print("Host metrics cadence and subscription checks passed for both runtimes")


if __name__ == "__main__":
    main()
