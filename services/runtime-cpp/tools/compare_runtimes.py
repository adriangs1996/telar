#!/usr/bin/env python3
import argparse
from datetime import datetime, timezone
import platform
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess
import tempfile
import time


def run_probe(binary, implementation, probe, workload, iterations, config_source=None, isolated_codex_home=False):
    with tempfile.TemporaryDirectory(prefix="telar-compare-", dir="/tmp") as directory:
        root = Path(directory)
        socket = root / "runtime.sock"
        environment = {key: value for key, value in os.environ.items() if not key.startswith("TELAR_")}
        environment.update({
            "XDG_CONFIG_HOME": str(root / "config"),
            "XDG_DATA_HOME": str(root / "data"),
            "XDG_STATE_HOME": str(root / "state"),
            "XDG_CACHE_HOME": str(root / "cache"),
            "TERM": "xterm-256color",
        })
        if isolated_codex_home:
            environment["CODEX_HOME"] = str(root / "codex-home")
        command = [str(binary), "--socket", str(socket)]
        if implementation == "zig":
            command = [str(binary), "server", "--socket", str(socket)]
        if config_source is not None:
            configuration = root / "config.lua"
            configuration.write_text(config_source)
            command.extend(["--config", str(configuration)])
        elif implementation == "zig":
            command.append("--no-config")

        with (root / "server.log").open("w+") as log:
            server = subprocess.Popen(command, env=environment, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 15
                while not socket.exists():
                    if server.poll() is not None or time.monotonic() > deadline:
                        raise RuntimeError("Runtime did not start")
                    time.sleep(0.01)

                dump = root / "screen.bin"
                result = subprocess.run(
                    [str(probe), str(socket), workload, str(iterations), str(dump)],
                    env=environment, capture_output=True, text=True, timeout=60,
                )
                if result.returncode != 0:
                    raise RuntimeError(result.stderr.strip())

                return json.loads(result.stdout), dump.read_bytes()
            except Exception as error:
                log.flush()
                log.seek(0)
                raise RuntimeError(f"{implementation}/{workload}: {error}\n{log.read()}") from error
            finally:
                if server.poll() is None:
                    server.terminate()
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()


def main():
    parser = argparse.ArgumentParser(description="Paired runtime comparison with an exact screen-state oracle")
    parser.add_argument("--zig", type=Path, required=True)
    parser.add_argument("--cpp", type=Path, required=True)
    parser.add_argument("--probe", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--config-source", type=Path, help="Use the same isolated Lua configuration for both runtimes")
    parser.add_argument("--pairs", type=int, default=1)
    parser.add_argument("--iterations", type=int, default=20)
    parser.add_argument("--workloads", nargs="+", default=["sparse", "full", "scroll", "unicode", "modes", "links", "colors", "mixed", "bulk", "graphemes"])
    parser.add_argument("--enforce", action="store_true", help="Require at least six C++ wins in seven pairs for every workload")
    parser.add_argument("--functional-only", action="store_true", help="Compare behavior; elapsed time includes intentional fixture waits and is not a performance gate")
    parser.add_argument("--isolated-codex-home", action="store_true", help="Give the runtime and probe a private Codex configuration directory")
    arguments = parser.parse_args()
    config_source = arguments.config_source.read_text() if arguments.config_source else None
    if arguments.pairs < 1 or arguments.iterations < 1:
        parser.error("--pairs and --iterations must be positive")
    if arguments.enforce and arguments.pairs < 7:
        parser.error("--enforce requires at least seven pairs")
    if arguments.enforce and arguments.functional_only:
        parser.error("--functional-only cannot enforce performance")
    report = {
        "measured_at": datetime.now(timezone.utc).isoformat(),
        "platform": platform.platform(),
        "architecture": os.uname().machine,
        "load": os.getloadavg(),
        "pairs": arguments.pairs,
        "iterations": arguments.iterations,
        "acceptance": "equivalence_only" if arguments.functional_only else "performance_and_equivalence" if arguments.enforce else "measurement",
        "configuration_sha256": hashlib.sha256(config_source.encode()).hexdigest() if config_source is not None else None,
        "isolated_codex_home": arguments.isolated_codex_home,
        "binaries": {
            name: {"path": str(path.resolve()), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
            for name, path in [("zig", arguments.zig), ("cpp", arguments.cpp), ("probe", arguments.probe)]
        },
        "cases": {},
    }

    for workload in arguments.workloads:
        pairs = []
        for pair in range(arguments.pairs):
            order = ["zig", "cpp"] if pair % 2 == 0 else ["cpp", "zig"]
            results = {}
            dumps = {}
            for implementation in order:
                try:
                    results[implementation], dumps[implementation] = run_probe(
                        getattr(arguments, implementation).resolve(), implementation,
                        arguments.probe.resolve(), workload, arguments.iterations,
                        config_source,
                        arguments.isolated_codex_home,
                    )
                except Exception as error:
                    report["failure"] = {"workload": workload, "pair": pair + 1, "implementation": implementation, "message": str(error)}
                    arguments.output.write_text(json.dumps(report, indent=2) + "\n")
                    raise

            if dumps["zig"] != dumps["cpp"]:
                for implementation, data in dumps.items():
                    arguments.output.with_suffix(f".{workload}.{implementation}.bin").write_bytes(data)
                differences = [index for index, (left, right) in enumerate(zip(dumps["zig"], dumps["cpp"])) if left != right]
                report["failure"] = {"workload": workload, "pair": pair + 1, "message": "Oracle mismatch", "lengths": {name: len(data) for name, data in dumps.items()}, "first_offsets": differences[:20]}
                arguments.output.write_text(json.dumps(report, indent=2) + "\n")
                raise RuntimeError(f"{workload}: oracle mismatch; lengths={list(map(len, dumps.values()))}; first offsets={differences[:20]}")

            results["digest"] = hashlib.sha256(dumps["zig"]).hexdigest()
            results["ratio"] = results["cpp"]["ns_per_iteration"] / results["zig"]["ns_per_iteration"]
            pairs.append(results)
            print(f"{workload} pair {pair + 1}: cpp/zig={results['ratio']:.3f}", flush=True)
            report["cases"][workload] = {
                "pairs": pairs,
                "wins": sum(pair["ratio"] <= 1 for pair in pairs),
                "median_ratio": statistics.median(pair["ratio"] for pair in pairs),
            }
            arguments.output.write_text(json.dumps(report, indent=2) + "\n")

    if arguments.enforce:
        failures = [name for name, case in report["cases"].items() if case["wins"] < arguments.pairs - 1]
        if failures:
            raise SystemExit("Performance gate failed: " + ", ".join(failures))


if __name__ == "__main__":
    main()
