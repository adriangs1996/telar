#!/usr/bin/env python3
"""Build and exercise the pinned terminal-browser inside Telar on Ghostty."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import sqlite3
import subprocess
import tempfile
import time


PINNED_REVISION = "cce10b6131d15bf46a3e4b8dc827e0544ff7fc65"
UPSTREAM = "https://github.com/zenbu-labs/terminal-browser.git"


def run(command: list[str], *, cwd: Path, env: dict[str, str] | None = None) -> None:
    subprocess.run(command, cwd=cwd, env=env, check=True)


def read_json_lines(path: Path) -> list[dict[str, object]]:
    if not path.exists():
        return []
    records: list[dict[str, object]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return records


def latest_matching(directory: Path, pattern: str) -> Path | None:
    matches = sorted(directory.glob(pattern), key=lambda path: path.stat().st_mtime_ns)
    return matches[-1] if matches else None


def counter_rates(samples: list[dict[str, object]], fields: list[str]) -> list[float]:
    """Per-sample rates of the summed cumulative counters, in units per second."""
    rates: list[float] = []
    for previous, current in zip(samples, samples[1:]):
        elapsed_ms = int(current.get("ts_ms", 0)) - int(previous.get("ts_ms", 0))
        if elapsed_ms <= 0:
            continue
        delta = sum(int(current.get(field, 0)) for field in fields) - sum(
            int(previous.get(field, 0)) for field in fields
        )
        rates.append(max(delta, 0) * 1000.0 / elapsed_ms)
    return rates


def steady_average(rates: list[float]) -> float:
    """Mean over the window without the two warm-up seconds and the final one."""
    window = rates[2:-1] if len(rates) > 3 else rates
    return sum(window) / len(window) if window else 0.0


def latest(samples: list[dict[str, object]], field: str) -> int:
    return int(samples[-1].get(field, 0)) if samples else 0


def frame_report(
    runtime_samples: list[dict[str, object]], client_samples: list[dict[str, object]]
) -> dict[str, object]:
    forwarded = counter_rates(runtime_samples, ["media_forwarded_frames"])
    published = counter_rates(runtime_samples, ["graphics_images_sent"])
    presented = counter_rates(client_samples, ["pane_shared_images", "pane_inline_images"])
    return {
        "forwarded_per_second": round(steady_average(forwarded), 2),
        "published_per_second": round(steady_average(published), 2),
        "presented_per_second": round(steady_average(presented), 2),
        "forwarded_series": [round(rate, 1) for rate in forwarded],
        "published_series": [round(rate, 1) for rate in published],
        "presented_series": [round(rate, 1) for rate in presented],
        "frame_bytes": max((int(s.get("graphics_transfer_bytes", 0)) for s in runtime_samples), default=0),
        "media_discarded_frames": latest(runtime_samples, "media_discarded_frames"),
        "media_unavailable_frames": latest(runtime_samples, "media_unavailable_frames"),
        "media_ingest_avg_us": latest(runtime_samples, "media_ingest_avg_us"),
        "media_ingest_max_us": latest(runtime_samples, "media_ingest_max_us"),
        "graphics_freeze_avg_us": latest(runtime_samples, "graphics_freeze_avg_us"),
        "graphics_freeze_max_us": latest(runtime_samples, "graphics_freeze_max_us"),
        "graphics_stage_blocked": latest(runtime_samples, "graphics_stage_blocked"),
        "graphics_stage_deferred": latest(runtime_samples, "graphics_stage_deferred"),
        "media_direct_frames": latest(runtime_samples, "media_direct_frames"),
        "media_file_frames": latest(runtime_samples, "media_file_frames"),
        "graphics_transfers_prepared": latest(runtime_samples, "graphics_transfers_prepared"),
        "graphics_transfers_adopted": latest(runtime_samples, "graphics_transfers_adopted"),
        "media_deferrals": latest(client_samples, "media_deferrals"),
        "pane_present_interval_avg_us": latest(client_samples, "pane_present_interval_avg_us"),
        "pane_present_interval_max_us": latest(client_samples, "pane_present_interval_max_us"),
        "shared_retire_latency_avg_us": latest(client_samples, "shared_retire_latency_avg_us"),
        "shared_retire_latency_max_us": latest(client_samples, "shared_retire_latency_max_us"),
        "shared_expiries": latest(client_samples, "shared_expiries"),
    }


def launch_ghostty(run_directory: Path, wrapper: Path) -> str:
    script = r'''
on run argv
  tell application "Ghostty"
    set config to new surface configuration
    set initial working directory of config to item 1 of argv
    set command of config to "/bin/sh " & quoted form of (item 2 of argv)
    set opened to new window with configuration config
    set target to focused terminal of selected tab of opened
    return (id of target) as text
  end tell
end run
'''
    return subprocess.check_output(
        ["osascript", "-e", script, str(run_directory), str(wrapper)], text=True
    ).strip()


def inject_ghostty_input(terminal_id: str) -> None:
    script = r'''
on run argv
  set targetId to item 1 of argv
  tell application "Ghostty"
    repeat with w in windows
      repeat with tb in tabs of w
        repeat with term in terminals of tb
          if (id of term) as text is targetId then
            focus term
            send mouse position x 1200 y 500 to term
            send mouse button left button action press to term
            send mouse button left button action release to term
            delay 0.2
            send key "a" action press to term
            send key "a" action release to term
            input text "a" to term
            return "sent"
          end if
        end repeat
      end repeat
    end repeat
  end tell
  return "not-found"
end run
'''
    result = subprocess.check_output(
        ["osascript", "-e", script, terminal_id], text=True
    ).strip()
    if result != "sent":
        raise RuntimeError(f"Ghostty input target disappeared: {terminal_id}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--terminal-browser-repo", type=Path)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--timeout", type=float, default=45.0)
    parser.add_argument("--keep", action="store_true")
    parser.add_argument(
        "--measure",
        type=float,
        default=0.0,
        metavar="SECONDS",
        help="keep the animated fixture running this long after it loads and "
        "report frames per second at each pipeline stage",
    )
    parser.add_argument(
        "--source",
        default="browser",
        metavar="browser|synthetic:WxH@FPS",
        help="what draws in the pane: the pinned terminal-browser (default) or "
        "telar-frame-source publishing WxH RGBA frames at FPS, which needs "
        "--measure and skips the browser checks",
    )
    parser.add_argument(
        "--transport",
        default="shm",
        choices=("shm", "file"),
        help="how the synthetic source hands frames over: POSIX shared memory "
        "objects or regular files rewritten in place (terminal-browser's choice)",
    )
    args = parser.parse_args()
    synthetic: tuple[int, int, int] | None = None
    if args.source != "browser":
        kind, _, geometry = args.source.partition(":")
        if kind != "synthetic" or args.measure <= 0:
            raise SystemExit("--source synthetic:WxH@FPS requires --measure SECONDS")
        size, _, rate = geometry.partition("@")
        width, _, height = size.partition("x")
        synthetic = (int(width), int(height), int(rate or 120))

    telar_root = Path(__file__).resolve().parents[1]
    owned_checkout: tempfile.TemporaryDirectory[str] | None = None
    browser_root: Path | None = None
    revision = "n/a"
    if synthetic is None:
        if args.terminal_browser_repo:
            browser_root = args.terminal_browser_repo.resolve()
        else:
            owned_checkout = tempfile.TemporaryDirectory(prefix="telar-terminal-browser-source-")
            browser_root = Path(owned_checkout.name) / "terminal-browser"
            run(["git", "clone", "--filter=blob:none", UPSTREAM, str(browser_root)], cwd=telar_root)
            run(["git", "checkout", "--detach", PINNED_REVISION], cwd=browser_root)

        revision = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=browser_root, text=True
        ).strip()
        if revision != PINNED_REVISION:
            raise SystemExit(f"expected terminal-browser {PINNED_REVISION}, found {revision}")

    if not args.skip_build:
        if browser_root is not None:
            run(["pnpm", "install", "--frozen-lockfile"], cwd=browser_root)
            run(["pnpm", "build"], cwd=browser_root)
        # Measurement wants the shipped optimization level with the telemetry
        # counters still compiled in; the plain check keeps the Debug build.
        zig_build = ["zig", "build"]
        if args.measure > 0:
            zig_build += ["-Doptimize=ReleaseFast", "-Ddiagnostics=true"]
        run(zig_build, cwd=telar_root)

    telar = telar_root / "zig-out/bin/telar"
    frame_source = telar_root / "zig-out/bin/telar-frame-source"
    cli = browser_root / "cli/dist/main.js" if browser_root is not None else frame_source
    for required in (telar, cli):
        if not required.exists():
            raise SystemExit(f"missing {required}; run without --skip-build")
    if shutil.which("osascript") is None or not Path("/Applications/Ghostty.app").exists():
        raise SystemExit("this verifier currently requires Ghostty.app on macOS")

    run_directory = Path(tempfile.mkdtemp(prefix="telar-terminal-browser-run-"))
    socket = run_directory / "runtime.sock"
    history = run_directory / "history.db"
    evidence = run_directory / "browser-evidence.jsonl"
    fixture = telar_root / "tests/terminal-browser/fixture.html"
    preload = telar_root / "tests/terminal-browser/preload.js"
    main_script = telar_root / "tests/terminal-browser/main.js"
    environment = os.environ.copy()
    environment.update(
        {
            "TELAR_SOCKET": str(socket),
            "TELAR_HISTORY": str(history),
            "TELAR_TERMINAL_BROWSER_EVIDENCE": str(evidence),
            "TELAR_TERMINAL_BROWSER_RUN_MS": str(int(max(8.0, args.measure) * 1000)),
            "XDG_DATA_HOME": str(run_directory / "terminal-browser-data"),
        }
    )

    if synthetic is None:
        child = [
            str(telar),
            "node",
            str(cli),
            "open",
            str(fixture),
            f"--preload={preload}",
            f"--main-script={main_script}",
            "--app-mode",
        ]
    else:
        width, height, rate = synthetic
        child = [
            str(telar),
            str(frame_source),
            "--width",
            str(width),
            "--height",
            str(height),
            "--fps",
            str(rate),
            "--seconds",
            str(int(args.measure) + 2),
            "--transport",
            args.transport,
        ]
    wrapper = run_directory / "launch.sh"
    wrapper.write_text(
        "#!/bin/sh\nset -eu\n"
        + "\n".join(
            f"export {name}={shlex.quote(environment[name])}"
            for name in (
                "TELAR_SOCKET",
                "TELAR_HISTORY",
                "TELAR_TERMINAL_BROWSER_EVIDENCE",
                "TELAR_TERMINAL_BROWSER_RUN_MS",
                "XDG_DATA_HOME",
            )
        )
        + f"\ncd {shlex.quote(str(telar_root))}\nexec {shlex.join(child)}\n",
        encoding="utf-8",
    )
    wrapper.chmod(0o700)

    terminal_id = launch_ghostty(run_directory, wrapper)

    # The fixture animates on requestAnimationFrame until its preload quits
    # the browser, so a longer measurement window only stretches that timer.
    deadline = time.monotonic() + args.timeout + args.measure
    completed = False
    input_injected = False
    if synthetic is not None:
        # The source runs for the measurement window and exits by itself.
        time.sleep(args.measure + 4)
        completed = True
    while synthetic is None and time.monotonic() < deadline:
        events = read_json_lines(evidence)
        if not input_injected and any(event.get("event") == "page-loaded" for event in events):
            inject_ghostty_input(terminal_id)
            input_injected = True
        if any(event.get("event") == "completed" for event in events):
            completed = True
            break
        time.sleep(0.1)

    time.sleep(1.5)
    subprocess.run([str(telar), "server", "stop"], cwd=telar_root, env=environment)
    if browser_root is not None:
        subprocess.run(["node", str(cli), "shutdown"], cwd=browser_root, env=environment)

    client_log = latest_matching(run_directory, "runtime.sock.client-*.log")
    runtime_log = latest_matching(run_directory, "runtime.sock.runtime-*.log")
    client_samples = read_json_lines(client_log) if client_log else []
    runtime_samples = read_json_lines(runtime_log) if runtime_log else []
    events = read_json_lines(evidence)
    history_commands = 0
    if history.exists():
        with sqlite3.connect(history) as database:
            history_commands = database.execute("SELECT count(*) FROM command").fetchone()[0]

    browser_checks = {
        "pinned_revision": revision == PINNED_REVISION,
        "page_loaded": any(event.get("event") == "page-loaded" for event in events),
        "page_completed": completed,
        "keyboard_reached_chromium": any(
            event.get("event") in {"key", "text-input"} for event in events
        ),
        "mouse_reached_chromium": any(event.get("event") == "pointer" for event in events),
        "hybrid_sidebar_emitted": any(
            int(sample.get("sidebar_graphics_flushed_bytes", 0)) > 0 for sample in client_samples
        ),
    }
    checks = {
        **(browser_checks if synthetic is None else {}),
        "exterior_kgp_supported": any(
            sample.get("kitty_graphics") == "supported" for sample in client_samples
        ),
        "pane_graphics_emitted": any(
            int(sample.get("pane_graphics_flushed_bytes", 0)) > 0 for sample in client_samples
        ),
        "runtime_forwarded_graphics": any(
            int(sample.get("graphics_messages", 0)) > 0 for sample in runtime_samples
        ),
        "no_pty_response_drops": bool(runtime_samples)
        and all(int(sample.get("pty_response_dropped", 0)) == 0 for sample in runtime_samples),
        "no_response_queue_drops": bool(runtime_samples)
        and all(int(sample.get("response_queue_dropped", 0)) == 0 for sample in runtime_samples),
        "no_client_resyncs": bool(runtime_samples)
        and all(int(sample.get("client_resyncs", 0)) == 0 for sample in runtime_samples),
        "no_media_resets": bool(runtime_samples)
        and all(int(sample.get("media_resets", 0)) == 0 for sample in runtime_samples),
        "no_media_drops": bool(runtime_samples)
        and all(
            int(sample.get("media_dropped_events", 0)) == 0
            and int(sample.get("media_dropped_bytes", 0)) == 0
            for sample in runtime_samples
        ),
        "history_isolated": history_commands == 0,
    }
    result: dict[str, object] = {
        "source": args.source,
        "transport": args.transport if synthetic is not None else "browser-chosen",
        "terminal_browser_revision": revision,
        "ghostty_version": subprocess.check_output(
            ["ghostty", "+version"], text=True
        ).splitlines()[0],
        "checks": checks,
        "browser_events": events,
        "run_directory": str(run_directory),
    }
    if args.measure > 0:
        result["frames"] = frame_report(runtime_samples, client_samples)
    result_path = telar_root / "zig-out/terminal-browser-verification.json"
    result_path.parent.mkdir(parents=True, exist_ok=True)
    result_path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2))

    success = all(checks.values())
    if success and not args.keep:
        shutil.rmtree(run_directory)
    elif not success:
        print(f"verification artifacts kept at {run_directory}")
    if owned_checkout is not None:
        owned_checkout.cleanup()
    return 0 if success else 1


if __name__ == "__main__":
    raise SystemExit(main())
