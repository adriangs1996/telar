#!/usr/bin/env python3
"""Alternate native animation probes; count changed states at Metal presentation."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import time


def summarize(report, expected_fps):
    if not report["display"]["display_sync_enabled"]:
        raise ValueError("display synchronization was disabled")
    if report["display"]["name"] != report["requested_screen"]:
        raise ValueError("the window manager moved the probe to a different display")
    measured = [frame for frame in report["presentations"] if 1 <= frame["cycle"] <= 12]
    # A discarded drawable reports zero: it was not presented. Its loss remains
    # visible in the gap between the surrounding positive presentation times.
    frames = sorted((frame for frame in measured if frame["presented_seconds"] > 0),
                    key=lambda frame: frame["presented_seconds"])
    if not frames:
        raise ValueError("no positive native presentation timestamps in the measured cycles")
    changes = []
    for frame in frames:
        if not changes or frame["cycle"] != changes[-1]["cycle"] or frame["value"] != changes[-1]["value"]:
            changes.append(frame)
    gaps = [1000 * (right["presented_seconds"] - left["presented_seconds"])
            for left, right in zip(changes, changes[1:])
            if left["cycle"] == right["cycle"]]
    if not gaps:
        raise ValueError("no changed animation states were presented")
    ordered = sorted(gaps)
    period = 1000 / expected_fps
    result = dict(samples=len(gaps), discarded_drawables=len(measured) - len(frames), p50_ms=statistics.median(gaps),
                  p95_ms=ordered[min(len(ordered) - 1, int(len(ordered) * .95))],
                  p99_ms=ordered[min(len(ordered) - 1, int(len(ordered) * .99))],
                  longest_stall_ms=max(gaps),
                  missed_refreshes=sum(max(0, round(gap / period) - 1) for gap in gaps))
    if report["mode"] == "continuous" and abs(result["p50_ms"] / period - 1) > .05:
        raise ValueError("the continuous-motion control did not qualify the requested display cadence")
    return result


def move_owned_window(process, monitor):
    for _ in range(40):
        if process.poll() is not None:
            raise RuntimeError("the probe exited before its window appeared")
        result = subprocess.run(["aerospace", "list-windows", "--monitor", "all", "--pid", str(process.pid),
                                 "--format", "%{window-id}"], text=True, capture_output=True, check=True)
        windows = result.stdout.split()
        if windows:
            window = windows[0]
            # Tool windows may already be floating and return a silent no-op error.
            # Moving remains mandatory; the native display is verified afterwards.
            subprocess.run(["aerospace", "layout", "--window-id", window, "floating"], capture_output=True)
            subprocess.run(["aerospace", "move-node-to-monitor", "--window-id", window,
                            "--focus-follows-window", monitor], check=True, capture_output=True)
            return
        time.sleep(.05)
    raise RuntimeError("the probe window did not appear in the window manager")


def measure(binary, destination, options, mode):
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(("QSG_", "QT_", "QML_", "DYLD_"))}
    environment["QT_QPA_PLATFORM"] = "cocoa"
    with destination.with_suffix(".log").open("w") as log:
        process = subprocess.Popen([str(binary), "--mode", mode, "--screen", str(options.screen)],
                                   stdout=subprocess.PIPE, stderr=log, text=True, env=environment)
        try:
            if options.aerospace_monitor:
                move_owned_window(process, options.aerospace_monitor)
            output, _ = process.communicate(timeout=30)
            if process.returncode:
                raise RuntimeError(f"probe exited {process.returncode}; see {destination.with_suffix('.log')}")
        except BaseException:
            process.kill()
            process.wait()
            raise
    report = json.loads(output)
    destination.write_text(json.dumps(report, indent=2) + "\n")
    return summarize(report, options.expected_fps)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("directory", type=Path, help="new result directory")
    parser.add_argument("--screen", type=int, default=0)
    parser.add_argument("--expected-fps", type=float, required=True)
    parser.add_argument("--pairs", type=int, default=7)
    parser.add_argument("--modes", nargs="+", choices=["tabs", "modal", "continuous"], default=["continuous", "modal", "tabs"])
    parser.add_argument("--aerospace-monitor", help="optionally float/move only the probe's window using AeroSpace")
    options = parser.parse_args()
    if options.expected_fps <= 0 or options.pairs < 1:
        parser.error("expected FPS and pair count must be positive")
    if options.aerospace_monitor and not shutil.which("aerospace"):
        parser.error("--aerospace-monitor requires AeroSpace")
    directory = options.directory.resolve()
    directory.mkdir(parents=True, exist_ok=False)
    binaries = {"baseline": options.baseline.resolve(), "candidate": options.candidate.resolve()}
    report = dict(scope="production modal/tab layout adapters and window pacer, isolated native rectangle scene; not full-client latency",
                  endpoint="positive MTLDrawable.presentedTime tagged with the synchronized rectangle position",
                  binaries={name: dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest())
                            for name, path in binaries.items()}, expected_fps=options.expected_fps,
                  screen=options.screen, warmup_cycles=2, measured_cycles=12, cycle_ms=400, runs=[])
    for pair in range(options.pairs):
        order = ["baseline", "candidate"] if pair % 2 == 0 else ["candidate", "baseline"]
        for mode in options.modes:
            for variant in order:
                destination = directory / f"{pair}-{mode}-{variant}.json"
                try:
                    summary = measure(binaries[variant], destination, options, mode)
                    row = dict(pair=pair, mode=mode, variant=variant, summary=summary)
                except (ValueError, RuntimeError, subprocess.SubprocessError) as error:
                    row = dict(pair=pair, mode=mode, variant=variant, error=str(error))
                report["runs"].append(row)
                (directory / "report.json").write_text(json.dumps(report, indent=2) + "\n")
                print(json.dumps(row), flush=True)
    if any("error" in row for row in report["runs"]):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
