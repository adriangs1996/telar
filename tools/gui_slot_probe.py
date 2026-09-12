#!/usr/bin/env python3
"""Measure native frame scheduling without adding production instrumentation.

Echo preloads the existing pixel-verifying probe beside the bounded trace probe.
Output uses gui_slot_workload.py. Runs own one isolated runtime and close only
their own native window. No trace file is written until GPU shutdown completes.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess

from echo_latency import percentile


def summarize(values):
    if not values:
        return {"n": 0}
    return dict(n=len(values), p50_ms=statistics.median(values),
                p95_ms=percentile(values, .95), p99_ms=percentile(values, .99),
                max_ms=max(values), total_ms=sum(values))


def analyze(path, window=None):
    trace = json.loads(path.read_text())
    if trace["dropped"]:
        raise RuntimeError(f'trace overflow: {trace["dropped"]} events')
    events = sorted(trace["events"], key=lambda item: item[1])
    marker = next((index for index, event in enumerate(events) if event[0] == "measure_start"), None)
    if marker is None or events[-1][0] != "close_end":
        raise RuntimeError("trace must cover measurement start through joined GPU shutdown")
    # Feedback may run between enabling the buffer and reserving its start marker.
    events = events[marker:]
    window_start, window_end = events[0][1], events[-1][1]
    if window is not None:
        window_start = max(window_start, window[0])
        window_end = min(window_end, window[1])
        if window_start >= window_end:
            raise RuntimeError("workload window does not overlap the recorded trace")
    has_state, dirty_flag, busy_flag, visible_flag, closed_flag = 1, 2, 4, 8, 16
    dirty = busy = visible = closed = False
    deadline = previous = events[0][1]
    demand = None
    pending_frame = None
    frames = {}
    dirty_busy = eligible_busy = 0.0
    starts = {}
    durations = {name: [] for name in ("drawable", "prepare", "encode", "wait", "commit", "pump", "input")}
    failed_gpu = failed_complete = 0
    requests = eligible_busy_requests = busy_requests = 0

    for kind, at, token, value, flags in events:
        # Replay every transition, including those before the observation window.
        # Clip interval totals without treating a boundary as a state change.
        if dirty and busy and visible and not closed:
            elapsed = max(0, at - previous)
            eligible = max(0, at - max(previous, deadline))
            dirty_busy += max(0, min(at, window_end) - max(previous, window_start))
            eligible_busy += max(0, min(at, window_end) - max(previous, window_start, deadline))
            if demand is not None:
                demand["dirty_busy_ms"] += elapsed * 1000
                demand["eligible_busy_ms"] += eligible * 1000
        previous = at

        if flags & has_state:
            dirty = bool(flags & dirty_flag)
            busy = bool(flags & busy_flag)
            visible = bool(flags & visible_flag)
            closed = bool(flags & closed_flag)
            deadline = value
        if kind == "request_begin" and not closed:
            if window_start <= at < window_end:
                requests += 1
                busy_requests += int(busy)
                eligible_busy_requests += int(busy and visible and at >= deadline)
            if demand is None:
                demand = dict(request_at=at, deadline=deadline,
                              dirty_busy_ms=0.0, eligible_busy_ms=0.0, request_observed=True)
            dirty = True
        elif kind == "prepare_begin":
            dirty = False
            pending_frame = demand or dict(request_at=at, deadline=at,
                                           dirty_busy_ms=0.0, eligible_busy_ms=0.0, request_observed=False)
            pending_frame["prepare_at"] = at
            pending_frame["request_to_prepare_ms"] = (at - pending_frame["request_at"]) * 1000
            pending_frame["cadence_bound_ms"] = max(
                0, min(at, pending_frame["deadline"]) - pending_frame["request_at"]) * 1000
            demand = None
        elif kind == "prepare_end":
            if pending_frame is not None:
                pending_frame["quads"] = value
                frames[token] = pending_frame
                pending_frame = None
        elif kind == "wait_begin":
            busy = True
        elif kind == "complete_begin":
            busy = False
            failed_complete += int(not value and window_start <= at < window_end)
        elif kind == "gpu_complete":
            failed_gpu += int(not value and window_start <= at < window_end)
        elif kind == "close_begin":
            closed = True

        if token:
            frame = frames.setdefault(token, {})
            if kind in ("wait_begin", "commit_begin", "commit_end", "gpu_complete", "complete_begin", "complete_end"):
                frame[kind] = at
            elif kind in ("gpu_start", "gpu_end"):
                frame[kind] = value
            elif kind == "frame_marker":
                frame["marker_sequence"] = int(value)

        phase, _, edge = kind.rpartition("_")
        if phase in durations:
            if edge == "begin":
                starts[phase] = at
            elif edge == "end" and phase in starts:
                began = starts.pop(phase)
                if window_start <= began and at <= window_end:
                    durations[phase].append((at - began) * 1000)

    all_prepared = [frame for frame in frames.values() if "prepare_at" in frame]
    prepared = [frame for frame in all_prepared if window_start <= frame["prepare_at"] < window_end]
    completed = [frame for frame in all_prepared
                 if window_start <= frame.get("gpu_complete", -1) < window_end]
    main_completed = [frame for frame in frames.values()
                      if window_start <= frame.get("complete_begin", -1) < window_end]
    contained = [frame for frame in prepared if frame["request_observed"]
                 and frame["request_at"] >= window_start
                 and "complete_end" in frame and frame["complete_end"] <= window_end]
    frame_samples = contained if window is not None else prepared
    completed_samples = contained if window is not None else completed
    samples = {name + "_ms": values for name, values in durations.items()}
    for name in ("dirty_busy_ms", "eligible_busy_ms", "request_to_prepare_ms", "cadence_bound_ms"):
        samples[name] = [frame[name] for frame in frame_samples]
    for name, start, end in (
        ("gpu_work_ms", "gpu_start", "gpu_end"),
        ("submit_to_gpu_start_ms", "commit_begin", "gpu_start"),
        ("gpu_end_to_feedback_ms", "gpu_end", "gpu_complete"),
        ("submit_to_feedback_ms", "commit_begin", "gpu_complete"),
        ("feedback_to_main_ms", "gpu_complete", "complete_begin"),
        ("slot_occupied_ms", "wait_begin", "complete_begin"),
    ):
        samples[name] = [(frame[end] - frame[start]) * 1000 for frame in completed_samples
                         if start in frame and end in frame]
    prepare_times = [frame["prepare_at"] for frame in prepared]
    samples["frame_interval_ms"] = [(right - left) * 1000
                                    for left, right in zip(prepare_times, prepare_times[1:])]
    span = window_end - window_start
    active_span = max(prepare_times) - min(prepare_times) if len(prepare_times) > 1 else 0
    summary = dict(
        viewport=trace["viewport"], events=sum(window_start <= event[1] <= window_end for event in events),
        elapsed_seconds=span, observation_start_s=window_start, observation_end_s=window_end,
        frames_prepared=len(prepared), frames_gpu_completed=len(completed),
        frames_main_completed=len(main_completed), frames_fully_contained=len(contained),
        prepared_frames_excluded_from_latency=len(prepared) - len(frame_samples),
        prepared_per_second=len(prepared) / span if span else 0,
        main_completed_per_second=len(main_completed) / span if span else 0,
        active_span_seconds=active_span,
        active_fps=(len(prepare_times) - 1) / active_span if active_span else 0,
        requests=requests, busy_requests=busy_requests,
        eligible_busy_requests=eligible_busy_requests,
        frames_with_eligible_busy_wait=sum(frame["eligible_busy_ms"] > 0 for frame in frame_samples),
        dirty_busy_ms_total=dirty_busy * 1000,
        dirty_eligible_busy_ms_total=eligible_busy * 1000,
        dirty_eligible_busy_percent=eligible_busy / span * 100 if span else 0,
        failed_gpu=failed_gpu, failed_complete=failed_complete,
        metrics={name: summarize(values) for name, values in samples.items()},
        windowed=window is not None,
        sample_policy="Method durations require both endpoints inside the window. Windowed frame latency requires observed request through main completion inside it. Counters count events inside the window; wait totals include clipped partial intervals.",
        limitation="Eligible busy wait counts work visible to this client under its current delivery contract; it does not estimate work the runtime has not published.",
    )
    return dict(summary=summary, samples=samples, frames=frames)


def analyze_workload(path, size_path, warmup=1.0):
    """Preserve the full report and add a state-aware window over measured output.

    Example: analyze_workload(Path('trace.json'), Path('size.json'), 1.0).
    CABase.h defines CACurrentMediaTime as mach_absolute_time in seconds;
    Python's macOS monotonic clock reports the same implementation.
    """
    size = json.loads(size_path.read_text())
    begin = size["started_monotonic_s"] + warmup
    end = size["finished_monotonic_s"]
    if warmup < 0 or begin >= end:
        raise ValueError("workload warmup must be nonnegative and shorter than the workload")
    result = analyze(path)
    result["workload_window"] = analyze(path, (begin, end))
    result["workload_window"]["bounds"] = dict(
        requested_start_s=begin, requested_end_s=end, warmup_seconds=warmup,
        clock="mach_absolute_time converted to seconds", size=size)
    if size.get("marker_updates"):
        result["freshness"] = analyze_freshness(result["workload_window"], size["marker_updates"])
    return result


def analyze_freshness(report, updates):
    """Measure the age of the source state used for each completed preparation.

    The marker comes from prepared quads, not a pixel readback or scanout.
    Skipped intermediate states are expected; every observed id must be real.
    """
    by_id = {sequence: (start, end) for sequence, start, end in updates}
    begin = report["summary"]["observation_start_s"]
    end = report["summary"]["observation_end_s"]
    rows = []
    for frame in report["frames"].values():
        prepared = frame.get("prepare_at", -1)
        completed = frame.get("gpu_complete")
        if not begin <= prepared < end or completed is None or completed > end:
            continue
        sequence = frame.get("marker_sequence")
        if sequence not in by_id:
            raise ValueError(f"prepared frame has no valid source marker: {sequence}")
        issued, written = by_id[sequence]
        if issued > prepared:
            raise ValueError("prepared state predates its source write")
        rows.append(dict(sequence=sequence, prepare_at=prepared, gpu_complete=completed,
                         state_age_at_prepare_ms=(prepared - issued) * 1000,
                         state_age_at_completion_ms=(completed - issued) * 1000,
                         source_write_ms=(written - issued) * 1000))
    if not rows:
        raise ValueError("no completed frames with source markers")
    return dict(endpoint="source write start to preparation / GPU feedback for the frame containing that marker; no pixel or scanout verification",
                frames=rows, unique_states=len({row["sequence"] for row in rows}),
                metrics={key: summarize([row[key] for row in rows]) for key in (
                    "state_age_at_prepare_ms", "state_age_at_completion_ms", "source_write_ms")})


def compile_probe(source, destination):
    subprocess.run(["clang", "-dynamiclib", "-O2", "-fobjc-arc", "-framework", "AppKit",
                    "-framework", "QuartzCore", "-framework", "Metal",
                    str(source), "-o", str(destination)], check=True)


def run(options):
    directory = options.directory.resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    binary = options.binary.resolve()
    source = Path(__file__).with_suffix(".m")
    library = directory / "slot-probe.dylib"
    compile_probe(source, library)
    libraries = [str(library)]
    if options.workload == "echo":
        pixel_library = directory / "pixel-probe.dylib"
        compile_probe(Path(__file__).with_name("gui_tui_latency.m"), pixel_library)
        libraries.append(str(pixel_library))

    config = directory / "config.lua"
    config.write_text("local t = require('telar')\nreturn { api_version = 2, client = { "
                      "sidebar = { visible = false, renderer = 'cells' }, pane_gaps = false, "
                      "bars = { bottom = { left = t.bar.static(' '), center = t.bar.static(' '), "
                      "right = t.bar.tabs() } } } }\n")
    env = {key: value for key, value in os.environ.items()
           if not key.startswith("TELAR_") and key != "DYLD_INSERT_LIBRARIES"}
    env.update(TELAR_SOCKET=str(directory / "runtime.sock"),
               TELAR_HISTORY=str(directory / "history.db"))
    subprocess.run([str(binary), "server", "--background", "--no-config"], env=env, check=True)
    launch_env = dict(env, DYLD_INSERT_LIBRARIES=":".join(libraries),
                      TELAR_SLOT_TRACE=str(directory / "trace.json"),
                      TELAR_SLOT_VIEWPORT=",".join(map(str, options.viewport)),
                      TELAR_SLOT_START=str(options.start),
                      TELAR_SLOT_SECONDS="0" if options.workload == "echo" else str(options.seconds - options.start))
    if options.marker:
        launch_env["TELAR_SLOT_MARKER"] = "1"
    fixture = [shutil.which("python3")]
    if options.workload == "echo":
        launch_env.update(TELAR_DISPLAY_RESULT=str(directory / "pixels.json"),
                          TELAR_DISPLAY_SAMPLES=str(options.samples + 20),
                          TELAR_DISPLAY_INPUT_METHOD=options.input_method)
        fixture += [str(Path(__file__).with_name("gui_tui_marker.py").resolve()),
                    str(directory / "size.json")]
    else:
        fixture += [str(Path(__file__).with_name("gui_slot_workload.py").resolve()),
                    "--mode", options.workload, "--rate", str(options.rate),
                    "--seconds", str(options.seconds - 4),
                    "--size-file", str(directory / "size.json")]
        if options.marker:
            fixture.append("--marker")
    manifest = dict(binary=str(binary), binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                    probe_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
                    workload=options.workload, rate=options.rate, viewport=options.viewport,
                    marker=options.marker,
                    start_seconds=options.start, close_seconds=options.seconds,
                    samples=options.samples if options.workload == "echo" else None,
                    input_method=options.input_method if options.workload == "echo" else None,
                    os=platform.platform(), machine=platform.machine())
    (directory / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    try:
        with (directory / "launch.log").open("w") as log:
            process = subprocess.Popen([str(binary), "gui", "--config", str(config), *fixture],
                                       env=launch_env, stdout=log, stderr=log)
            try:
                process.wait(timeout=105 if options.workload == "echo" else options.seconds + 20)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
                raise
            if process.returncode:
                raise RuntimeError(f"GUI exited with {process.returncode}: {directory}")
    finally:
        subprocess.run([str(binary), "server", "stop"], env=env,
                       stdout=subprocess.DEVNULL, timeout=10, check=False)
    result = analyze(directory / "trace.json") if options.workload == "echo" else analyze_workload(
        directory / "trace.json", directory / "size.json", options.workload_warmup)
    result["manifest"] = manifest
    if options.workload == "echo":
        pixels = json.loads((directory / "pixels.json").read_text())
        if pixels["failed"] or len(pixels["gpu_ms"]) != options.samples + 20:
            raise RuntimeError(f"pixel verification incomplete: {directory}")
        result["pixels"] = {"warmup": 20, "latency": summarize(pixels["gpu_ms"][20:]),
                            "gpu_work": summarize(pixels["gpu_work_ms"][20:])}
    result["size"] = json.loads((directory / "size.json").read_text())
    (directory / "analysis.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"directory": str(directory), **result["summary"],
                      **({"pixels": result["pixels"]} if "pixels" in result else {})}, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path, nargs="?")
    parser.add_argument("directory", type=Path, nargs="?")
    parser.add_argument("--analyze", type=Path, help="analyze an existing trace without launching a GUI")
    parser.add_argument("--size-file", type=Path, help="add workload-window statistics to --analyze")
    parser.add_argument("--workload-warmup", type=float, default=1)
    parser.add_argument("--workload", choices=["echo", "scroll", "full"], default="echo")
    parser.add_argument("--samples", type=int, default=100)
    parser.add_argument("--input-method", choices=["key", "text"], default="text")
    parser.add_argument("--seconds", type=float, default=16)
    parser.add_argument("--start", type=float, default=3)
    parser.add_argument("--rate", type=int, default=120)
    parser.add_argument("--marker", action="store_true", help="measure source-state age from a sequence in prepared quads")
    parser.add_argument("--viewport", type=int, nargs=2, default=[1900, 2112])
    options = parser.parse_args()
    if options.analyze:
        result = analyze_workload(options.analyze, options.size_file, options.workload_warmup) \
            if options.size_file else analyze(options.analyze)
        print(json.dumps(result, indent=2))
        return
    if options.size_file:
        parser.error("--size-file requires --analyze")
    if options.marker and options.workload == "echo":
        parser.error("--marker requires scroll or full output")
    if not options.binary or not options.directory:
        parser.error("binary and directory are required unless --analyze is used")
    if platform.system() != "Darwin":
        parser.error("the native probe requires a macOS graphical login")
    if not 1 <= options.samples <= 400 or not 6 <= options.seconds <= 64:
        parser.error("samples must be 1..400 and seconds 6..64")
    if not 0 <= options.start < options.seconds or not 1 <= options.rate <= 240:
        parser.error("start must precede close and rate must be 1..240")
    if any(value < 1 or value > 8192 for value in options.viewport):
        parser.error("viewport dimensions must be 1..8192")
    run(options)


if __name__ == "__main__":
    main()
