#!/usr/bin/env python3
"""Run two instrumented runtimes in interleaved blocks and keep each run's client queue trace.

Each side is LABEL:TELAR:PROBE, where TELAR is the binary the CLI checks start (`telar` in the module tree,
`telar-runtime` in the header tree) and PROBE is checkpoint-probe for `server-cli` or pane-traffic-probe
for `traffic`. Both sides are built by instrument.py. Blocks alternate the order of the sides (A B, B A, ...)
so that drift in the machine falls on both.

server-cli  runs check_server_cli.check_runtime, the server-cli-tests scenario, once per iteration.
traffic     starts a runtime, lets pane-traffic-probe read a pane that prints bursts of text for --seconds
            and stops the runtime through the probe.

--load N starts N `/usr/bin/yes` for the whole measurement and stops them by their exact PIDs.
"""
import argparse
import json
import os
from pathlib import Path
import runpy
import signal
import subprocess
import sys
import tempfile
import time
import traceback

PANE_COMMAND = ["/bin/sh", "-c", "while :; do /usr/bin/seq 1 400; /bin/sleep 0.02; done"]


def parse_side(text):
    label, telar, probe = text.split(":", 2)
    return {"label": label, "telar": Path(telar).resolve(), "probe": Path(probe).resolve()}


class Load:
    def __init__(self, count, record):
        self.count = count
        self.record = record
        self.children = []

    def __enter__(self):
        for _ in range(self.count):
            self.children.append(subprocess.Popen(["/usr/bin/yes"], stdout=subprocess.DEVNULL, start_new_session=True))

        self.record.write_text("".join(f"{child.pid}\n" for child in self.children))
        return self

    def __exit__(self, *_):
        for child in self.children:
            if child.poll() is None:
                os.kill(child.pid, signal.SIGTERM)

        for child in self.children:
            child.wait()


def signature(error):
    text = f"{type(error).__name__}: {error}"
    if "Checkpoint probe failed" in text:
        return "a:" + text.split("Checkpoint probe failed: ", 1)[1][:80]
    if isinstance(error, FileNotFoundError) and "session.ckpt.previous" in text:
        return "b:previous-missing"
    return f"other:{text[:120]}"


def server_cli(side, trace, check):
    os.environ["QUEUE_TRACE_DIR"] = str(trace)
    try:
        check(side["telar"], side["probe"])
        return "pass", ""
    except BaseException as error:
        return signature(error), "".join(traceback.format_exception(error))
    finally:
        os.environ.pop("QUEUE_TRACE_DIR", None)


def traffic(side, trace, seconds):
    with tempfile.TemporaryDirectory(prefix="telar-queue-", dir="/tmp") as directory:
        root = Path(directory).resolve()
        environment = {key: value for key, value in os.environ.items() if not key.startswith("TELAR_")}
        environment.update({"HOME": str(root / "home"), "XDG_RUNTIME_DIR": str(root / "run"),
                            "XDG_DATA_HOME": str(root / "data"), "XDG_CONFIG_HOME": str(root / "config"),
                            "XDG_CACHE_HOME": str(root / "cache"), "XDG_STATE_HOME": str(root / "state"),
                            "TMPDIR": str(root), "QUEUE_TRACE_DIR": str(trace)})
        (root / "home").mkdir(mode=0o700)
        (root / "run").mkdir(mode=0o700)
        socket = root / "runtime.sock"
        subprocess.run([str(side["telar"]), "server", "--background", "--socket", str(socket), "--no-config"],
                       env=environment, check=True, capture_output=True, timeout=15)
        deadline = time.monotonic() + 12
        while not socket.exists():
            if time.monotonic() >= deadline:
                return "other:runtime did not start", ""
            time.sleep(0.01)

        probe = subprocess.run([str(side["probe"]), str(socket), str(seconds), *PANE_COMMAND],
                               env=environment, capture_output=True, text=True, timeout=seconds + 30)
        deadline = time.monotonic() + 12
        while socket.exists():
            if time.monotonic() >= deadline:
                subprocess.run([str(side["telar"]), "server", "stop", "--socket", str(socket)], env=environment, capture_output=True, timeout=15)
                return "other:runtime did not stop", probe.stderr
            time.sleep(0.01)

        if probe.returncode != 0:
            return "a:" + probe.stderr.strip()[:80], probe.stderr

        (trace / "probe.json").write_text(probe.stdout)
        return "pass", ""


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("scenario", choices=("server-cli", "traffic"))
    parser.add_argument("--side", action="append", type=parse_side, required=True)
    parser.add_argument("--check", type=Path, help="check_server_cli.py for server-cli")
    parser.add_argument("--blocks", type=int, default=10)
    parser.add_argument("--per-block", type=int, default=20)
    parser.add_argument("--seconds", type=float, default=3.0)
    parser.add_argument("--load", type=int, default=0)
    parser.add_argument("--out", type=Path, required=True)
    arguments = parser.parse_args()
    # The runtime runs in the background from another directory: the trace directory must be absolute.
    arguments.out = arguments.out.resolve()
    arguments.out.mkdir(parents=True, exist_ok=True)
    (arguments.out / "pid").write_text(f"{os.getpid()}\n")
    check = runpy.run_path(str(arguments.check))["check_runtime"] if arguments.scenario == "server-cli" else None
    results = []

    with Load(arguments.load, arguments.out / "load.pids"):
        for block in range(arguments.blocks):
            order = arguments.side if block % 2 == 0 else list(reversed(arguments.side))
            for side in order:
                for iteration in range(arguments.per_block):
                    trace = arguments.out / side["label"] / f"b{block:02}-{iteration:03}"
                    trace.mkdir(parents=True)
                    started = time.time()
                    if check is not None:
                        outcome, detail = server_cli(side, trace, check)
                    else:
                        outcome, detail = traffic(side, trace, arguments.seconds)

                    record = {"side": side["label"], "block": block, "iteration": iteration, "outcome": outcome,
                              "seconds": round(time.time() - started, 3), "load": os.getloadavg()[0]}
                    (trace / "outcome.json").write_text(json.dumps(record) + "\n")
                    if detail:
                        (trace / "failure.txt").write_text(detail)

                    results.append(record)
                    print(json.dumps(record), flush=True)

    summary = {}
    for record in results:
        key = f"{record['side']} {record['outcome'].split(':')[0]}"
        summary[key] = summary.get(key, 0) + 1

    (arguments.out / "summary.json").write_text(json.dumps({"arguments": sys.argv[1:], "summary": summary}, indent=1) + "\n")
    print(json.dumps(summary), flush=True)


if __name__ == "__main__":
    main()
