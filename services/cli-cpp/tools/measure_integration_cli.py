#!/usr/bin/env python3
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile
import time

from check_integration import PROVIDERS, normalize, snapshot


def run(binary, provider, iterations):
    samples = []
    digest = None
    for _ in range(iterations):
        with tempfile.TemporaryDirectory(prefix="telar-integration-perf-", dir="/tmp") as temporary:
            root = Path(temporary).resolve()
            home = root / "home"
            home.mkdir(mode=0o700)
            environment = {key: value for key, value in os.environ.items()
                           if not key.startswith(("TELAR_", "XDG_")) and key not in {item[2] for item in PROVIDERS.values()}}
            environment.update(HOME=str(home), TMPDIR=str(root))
            started = time.perf_counter_ns()
            result = subprocess.run([str(binary), "integration", "install", provider], env=environment,
                                    cwd=root, capture_output=True, text=True, timeout=20)
            elapsed = time.perf_counter_ns() - started
            if result.returncode:
                raise RuntimeError(result.stderr)
            output = {"stdout": normalize(result.stdout, root, binary), "files": snapshot(root, binary)}
            current = hashlib.sha256(json.dumps(output, sort_keys=True).encode()).hexdigest()
            if digest is not None and current != digest:
                raise RuntimeError("Integration output changed between identical installations")
            digest = current
            samples.append(elapsed)
    return {"samples_ns": samples, "ns_per_iteration": statistics.mean(samples), "digest": digest}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--zig", type=Path, required=True)
    parser.add_argument("--cpp", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--iterations", type=int, default=16)
    arguments = parser.parse_args()
    binaries = {name: getattr(arguments, name).resolve() for name in ("zig", "cpp")}
    report = {"measured_at": datetime.now(timezone.utc).isoformat(), "platform": platform.platform(), "load": os.getloadavg(),
              "scope": "Process startup and fresh integration installation, including atomic writes of hooks/extensions and both skills",
              "binaries": {name: {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()} for name, path in binaries.items()}, "cases": {}}
    for provider in PROVIDERS:
        for binary in binaries.values():
            run(binary, provider, 2)
        pairs = []
        for index in range(7):
            pair = {}
            for name in (("zig", "cpp") if index % 2 == 0 else ("cpp", "zig")):
                pair[name] = run(binaries[name], provider, arguments.iterations)
            if pair["zig"]["digest"] != pair["cpp"]["digest"]:
                raise RuntimeError("Integration installations differ between runtimes")
            pair["ratio"] = pair["cpp"]["ns_per_iteration"] / pair["zig"]["ns_per_iteration"]
            pairs.append(pair)
            report["cases"][provider] = {"pairs": pairs, "wins": sum(item["ratio"] <= 1 for item in pairs),
                                         "median_ratio": statistics.median(item["ratio"] for item in pairs)}
            arguments.output.write_text(json.dumps(report, indent=2) + "\n")
            print(f"{provider} pair {index + 1}: {pair['ratio']:.4f}", flush=True)


if __name__ == "__main__":
    main()
