#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import stat
import subprocess
import tempfile
import time


def fingerprint(path):
    return {"path": str(path.resolve()), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def check(arguments):
    with tempfile.TemporaryDirectory(prefix="telar-telemetry-", dir="/tmp") as temporary:
        root = Path(temporary)
        socket = root / "runtime.sock"
        orphan = root / "runtime.sock.runtime-4294967295.log"
        retained = root / "unrelated.runtime-4294967295.log"
        orphan.write_text("old diagnostics")
        retained.write_text("keep")
        environment = {key: value for key, value in os.environ.items() if not key.startswith("TELAR_")}
        for name, directory in {"HOME": "home", "XDG_CONFIG_HOME": "config", "XDG_DATA_HOME": "data", "XDG_STATE_HOME": "state", "XDG_CACHE_HOME": "cache"}.items():
            path = root / directory
            path.mkdir()
            environment[name] = str(path)
        environment["SHELL"] = "/bin/sh"
        environment["TERM"] = "xterm-256color"
        configuration = root / "runtime.lua"
        configuration.write_text('return {api_version=2,runtime={session={persist=false},proxy={enabled=true,ca_dir="proxy",capture={enabled=true}}}}\n')
        command = [str(arguments.runtime.resolve()), "server", "--socket", str(socket), "--config", str(configuration)]
        with (root / "server.log").open("w+") as log:
            runtime = subprocess.Popen(command, env=environment, stdout=log, stderr=log)
            retained_graphics = None
            try:
                deadline = time.monotonic() + 30
                while not socket.exists():
                    if runtime.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError("Runtime did not start")
                    time.sleep(0.01)

                subprocess.run([str(arguments.probe.resolve()), str(socket), "sparse", "10", str(root / "screen.bin")], env=environment, check=True, capture_output=True, timeout=30)
                subprocess.run([str(arguments.proxy_probe.resolve()), str(socket), "proxy-status", "1", str(root / "proxy.bin")], env=environment, check=True, capture_output=True, timeout=30)
                if arguments.graphics_probe and not arguments.retain_graphics:
                    subprocess.run([str(arguments.graphics_probe.resolve()), str(socket), "graphics-file-atomic-shared", "2", str(root / "graphics.bin")], env=environment, check=True, capture_output=True, timeout=30)
                if arguments.shell_probe:
                    subprocess.run([str(arguments.shell_probe.resolve()), str(socket), "shell-capture-cwd", "1", str(root / "history.bin")], env=environment, check=True, capture_output=True, timeout=30)
                if arguments.retain_graphics:
                    retained_graphics = subprocess.Popen([str(arguments.graphics_probe.resolve()), str(socket), "graphics-file-atomic-shared", "2", str(root / "graphics.bin"), "retain"],
                                                         env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                    readable, _, _ = select.select([retained_graphics.stdout], [], [], 30)
                    if not readable or retained_graphics.stdout.readline() != "retained\n":
                        raise RuntimeError("Graphics fixture did not retain its live pane")
                path = root / f"runtime.sock.runtime-{runtime.pid}.log"
                if arguments.enabled:
                    deadline = time.monotonic() + 10
                    samples = []
                    while time.monotonic() < deadline:
                        complete_lines = path.read_text().split("\n")[:-1] if path.exists() else []
                        samples = [json.loads(line) for line in complete_lines]
                        graphics_ready = not arguments.graphics_probe or (samples and samples[-1]["graphics_images_sent"] >= 2)
                        if arguments.retain_graphics:
                            graphics_ready = graphics_ready and samples[-1]["pane_media_used"] > 0 and samples[-1]["media_queue_byte_high_water"] > 0 and samples[-1]["graphics_resident_bytes"] > 0 and samples[-1]["graphics_busy_panes"] == 0
                        observation_ready = not arguments.shell_probe or (samples and samples[-1]["history_captured"] >= 5 and samples[-1]["system_sample_age_ms"] is not None)
                        if len(samples) >= 2 and samples[-1]["proxy_rejected_connections"] > 0 and samples[-1]["frames"] > 0 and graphics_ready and observation_ready:
                            break
                        if runtime.poll() is not None:
                            raise RuntimeError("Runtime exited while sampling")
                        time.sleep(0.02)

                    assert samples, "Telemetry did not produce a sample"
                    latest = samples[-1]
                    assert stat.S_IMODE(path.stat().st_mode) == 0o600
                    assert max(map(len, path.read_bytes().splitlines())) < 12288
                    assert latest["role"] == "runtime" and latest["proxy_active"] == 1
                    for name in ["client_messages", "pty_bytes", "frames", "frame_cells", "frame_bytes", "rss_bytes", "heap_live_bytes", "heap_live_allocs", "heap_allocs", "interactive_allocs", "interactive_vt_allocs", "vt_scrollback_bytes", "vt_screen_bytes", "observation_allocs", "proxy_rejected_connections"]:
                        assert latest[name] > 0, (name, latest[name])
                    if arguments.graphics_probe:
                        for name in ["media_bytes", "media_forwarded_frames", "media_direct_frames", "media_file_frames", "media_ingest_max_us", "graphics_messages", "graphics_bytes", "graphics_images_sent", "graphics_placements_sent", "graphics_transfers_adopted"]:
                            assert latest[name] > 0, (name, latest[name])
                        assert latest["graphics_freeze_avg_us"] == 0
                        assert latest["graphics_freeze_max_us"] == 0
                        assert latest["media_failures"] == 0
                        assert latest["media_resets"] == 0
                        if arguments.retain_graphics:
                            for name in ["pane_media_used", "media_queue_event_high_water", "media_queue_byte_high_water", "graphics_images", "graphics_placements", "graphics_resident_bytes"]:
                                assert latest[name] > 0, (name, latest[name])
                    if arguments.shell_probe:
                        for name in ["history_candidate_input_bytes", "history_captured", "history_pty_submissions", "history_pty_captures", "history_queries", "sqlite_writes", "history_sqlite_bytes", "system_sample_max_us", "agent_process_inspections"]:
                            assert latest[name] > 0, (name, latest[name])
                        assert latest["history_dropped"] == 0
                        assert latest["history_observation_failures"] == 0
                        assert latest["system_sample_age_ms"] is not None
                    for sample in samples:
                        assert sample["media_queue_events"] <= sample["media_queue_event_high_water"]
                        assert sample["media_queue_bytes"] <= sample["media_queue_byte_high_water"]
                        assert sample["pane_media_used"] <= sample["graphics_budget_used"]
                        assert sample["response_queue_depth"] <= sample["response_queue_high_water"] <= 128 * sample["client_count"]
                        assert sample["response_queue_dropped"] >= 0
                    for earlier, later in zip(samples, samples[1:]):
                        assert later["uptime_ms"] >= earlier["uptime_ms"]
                        for name in ["frames", "pty_bytes", "client_messages", "heap_allocs", "proxy_rejected_connections"]:
                            assert later[name] >= earlier[name], name
                        if arguments.graphics_probe:
                            for name in ["media_bytes", "media_forwarded_frames", "graphics_messages", "graphics_bytes", "graphics_images_sent", "graphics_placements_sent", "graphics_transfers_prepared", "graphics_transfers_staged", "graphics_transfers_adopted", "graphics_stage_blocked", "graphics_stage_deferred", "agent_process_inspections", "agent_process_misses"]:
                                assert later[name] >= earlier[name], name
                        if arguments.shell_probe:
                            for name in ["history_candidate_input_bytes", "history_captured", "history_dropped", "history_queries", "sqlite_writes"]:
                                assert later[name] >= earlier[name], name
                else:
                    time.sleep(1.2)
                    assert not path.exists(), "Default Release emitted telemetry"
                    samples = []

                assert not orphan.exists(), "An orphan diagnostic log survived startup"
                assert retained.read_text() == "keep", "Startup removed an unrelated file"
                return {"samples": samples, "mode": "enabled" if arguments.enabled else "disabled", "passed": True}
            except Exception as error:
                log.flush()
                log.seek(0)
                raise RuntimeError(f"{error}\n{log.read()}") from error
            finally:
                retained_error = None
                if retained_graphics is not None:
                    try:
                        _, stderr = retained_graphics.communicate("\n", timeout=10)
                        if retained_graphics.returncode:
                            retained_error = f"Retained graphics fixture failed: {stderr}"
                    except subprocess.TimeoutExpired:
                        retained_graphics.kill()
                        retained_graphics.wait()
                        retained_error = "Retained graphics fixture did not stop"
                if runtime.poll() is None:
                    runtime.terminate()
                try:
                    runtime.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    runtime.kill()
                    runtime.wait()
                log.flush()
                log.seek(0)
                diagnostics = log.read()
                if runtime.returncode != 0 or "ERROR: AddressSanitizer" in diagnostics or "runtime error:" in diagnostics:
                    raise RuntimeError(f"Runtime shutdown failed ({runtime.returncode})\n{diagnostics}")
                if retained_error:
                    raise RuntimeError(retained_error)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", required=True, type=Path)
    parser.add_argument("--probe", required=True, type=Path)
    parser.add_argument("--proxy-probe", required=True, type=Path)
    parser.add_argument("--graphics-probe", type=Path)
    parser.add_argument("--shell-probe", type=Path)
    parser.add_argument("--retain-graphics", action="store_true")
    parser.add_argument("--enabled", action="store_true")
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    if arguments.retain_graphics and not arguments.graphics_probe:
        parser.error("--retain-graphics requires --graphics-probe")
    report = {"runtime": fingerprint(arguments.runtime), "probe": fingerprint(arguments.probe), "proxy_probe": fingerprint(arguments.proxy_probe)}
    if arguments.graphics_probe:
        report["graphics_probe"] = fingerprint(arguments.graphics_probe)
    if arguments.shell_probe:
        report["shell_probe"] = fingerprint(arguments.shell_probe)
    try:
        report.update(check(arguments))
    except Exception as error:
        report.update(passed=False, error=str(error))
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"passed": report["passed"], "samples": len(report.get("samples", [])), "error": report.get("error")}))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
