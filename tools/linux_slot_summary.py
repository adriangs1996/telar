#!/usr/bin/env python3
"""Summarize Vulkan/native-slot timing without mistaking FIFO waits for GPU work."""
import argparse
import bisect
import json
from pathlib import Path


def distribution(values):
    values = sorted(values)
    if not values:
        return None

    def percentile(fraction):
        position = (len(values) - 1) * fraction
        low = int(position)
        high = min(low + 1, len(values) - 1)
        return values[low] + (values[high] - values[low]) * (position - low)

    return {"n": len(values), "p50": percentile(.5), "p95": percentile(.95),
            "p99": percentile(.99), "max": values[-1], "mean": sum(values) / len(values)}


def summarize(raw, window=(3.0, None), workload=None):
    warmup_seconds, duration_seconds = window
    if raw["frame_overflow"] or raw["event_overflow"]:
        raise ValueError("Probe overflow: shorten the run before interpreting timings")
    if not raw["frames"]:
        raise ValueError("No Vulkan frames were recorded")
    origin = round(workload["started_monotonic_s"] * 1e9) if workload else raw["frames"][0]["acquire_begin"]
    start = origin + int(warmup_seconds * 1e9)
    end = start + int(duration_seconds * 1e9) if duration_seconds else 2**64 - 1
    if workload:
        end = min(end, round(workload["finished_monotonic_s"] * 1e9))
    events = sorted(raw["events"], key=lambda event: event[1])
    native = {}
    render_begin = None
    snapshots = []
    for kind, time, token, detail in events:
        if kind == 0:
            snapshots.append((time, token, detail))
        elif kind == 1:
            render_begin = time
        elif kind in (2, 3, 4, 5, 6):
            entry = native.setdefault(token, {"token": token})
            entry[{2: "render_end", 3: "enqueue", 4: "complete", 5: "worker_begin", 6: "worker_end"}[kind]] = time
            if kind == 2:
                entry["render_begin"] = render_begin
                entry["quads"] = detail
            if kind == 4:
                entry["outcome"] = detail
                if snapshots:
                    _, flags, deadline = snapshots[-1]
                    snapshots.append((time, flags & ~4, deadline))
        elif kind == 7:
            end = min(end, time)

    workers = sorted((entry for entry in native.values() if "worker_begin" in entry),
                     key=lambda entry: entry["worker_begin"])
    worker_times = [entry["worker_begin"] for entry in workers]
    good = []
    rejected = 0
    for frame in raw["frames"]:
        if not start <= frame["acquire_begin"] < end:
            continue
        required = ("acquire_end", "encode_begin", "encode_end", "submit_begin", "submit_end",
                    "present_begin", "present_end", "fence_begin", "fence_end")
        if (not all(frame[key] for key in required) or frame["acquired"] not in (0, 1000001003)
                or frame["submitted"] != 0 or frame["presented"] not in (0, 1000001003)
                or frame["completed"] != 0):
            rejected += 1
            continue
        sample = dict(frame)
        index = bisect.bisect_right(worker_times, frame["acquire_begin"]) - 1
        if index >= 0:
            worker = workers[index]
            if frame["acquire_begin"] <= worker.get("worker_end", 0):
                sample["native"] = worker
        good.append(sample)
    if not good:
        raise ValueError("No complete frames in the selected interval")
    end = min(end, max((event[1] for event in events), default=good[-1]["fence_end"]))
    metrics = {}
    metric_samples = {}

    def record(name, values):
        metric_samples[name] = values
        metrics[name] = distribution(values)

    pairs = {
        "acquire_ms": ("acquire_begin", "acquire_end"),
        "encode_ms": ("encode_begin", "encode_end"),
        "resource_prepare_ms": ("encode_begin", "resources_end"),
        "submit_call_ms": ("submit_begin", "submit_end"),
        "present_call_ms": ("present_begin", "present_end"),
        "render_fence_wait_ms": ("fence_begin", "fence_end"),
        "submit_to_fence_return_ms": ("submit_begin", "fence_end"),
        "renderer_ms": ("acquire_begin", "fence_end"),
    }
    for name, (first, last) in pairs.items():
        record(name, [(frame[last] - frame[first]) / 1e6 for frame in good])
    record("present_fence_wait_ms", [frame["present_fence_wait_ns"] / 1e6 for frame in good])
    record("gpu_interval_ms", [frame["gpu_ticks"] * raw["timestamp_period_ns"] / 1e6
                               for frame in good if frame["gpu_ticks"]])
    record("quads", [frame["quads"] for frame in good])
    record("frame_interval_ms", [(right["acquire_begin"] - left["acquire_begin"]) / 1e6
                                  for left, right in zip(good, good[1:])])
    for name, first, last in (
        ("render_cpu_ms", "render_begin", "render_end"),
        ("worker_dispatch_ms", "enqueue", "worker_begin"),
        ("worker_ms", "worker_begin", "worker_end"),
        ("main_completion_delay_ms", "worker_end", "complete"),
        ("native_slot_occupied_ms", "enqueue", "complete"),
    ):
        record(name, [(frame["native"][last] - frame["native"][first]) / 1e6
                      for frame in good if all(frame.get("native", {}).get(key) for key in (first, last))])

    gate = {"dirty_busy_ns": 0, "dirty_busy_callback_ns": 0, "dirty_busy_deadline_ns": 0,
            "eligible_slot_wait_ns": 0, "eligible_intervals": 0}
    eligible = []
    for (time, flags, deadline), (next_time, _, _) in zip(snapshots, snapshots[1:]):
        low, high = max(time, start), min(next_time, end)
        if high <= low or flags & 7 != 7 or flags & 16:
            continue
        gate["dirty_busy_ns"] += high - low
        if flags & 8:
            gate["dirty_busy_callback_ns"] += high - low
            continue
        ready = max(low, deadline)
        gate["dirty_busy_deadline_ns"] += max(0, min(high, deadline) - low)
        if ready < high:
            gate["eligible_slot_wait_ns"] += high - ready
            gate["eligible_intervals"] += 1
            eligible.append((ready, high))
    eligible_by_frame = []
    for frame in good:
        entry = frame.get("native", {})
        if "enqueue" not in entry or "complete" not in entry:
            continue
        waited = sum(max(0, min(high, entry["complete"]) - max(low, entry["enqueue"])) for low, high in eligible)
        eligible_by_frame.append(waited / 1e6)
    record("occupied_frame_eligible_slot_wait_ms", eligible_by_frame)
    return {
        "device": raw["device"], "present_mode": raw["present_mode"],
        "timestamp_queries_enabled": raw.get("timestamp_queries_enabled", False),
        "swapchain_images": raw["swapchain_images"], "start_ns": start, "end_ns": end,
        "selected_seconds": (end - start) / 1e9, "frames": len(good), "rejected_frames": rejected,
        "viewports": sorted({(frame["width"], frame["height"]) for frame in good}),
        "native_frames_matched": sum("native" in frame for frame in good),
        "gpu_allocated_bytes_in_selected_frames": sum(frame["allocated_bytes"] for frame in good),
        "atlas_uploaded_bytes_in_selected_frames": sum(frame["atlas_bytes"] for frame in good),
        "metrics": metrics, "metric_samples": metric_samples, "gates": gate,
        "limitations": [
            "GPU timestamps include queue-side stalls and image-acquisition waits; they are not active execution time.",
            "llvmpipe timestamps measure software Vulkan on VM CPUs, not a hardware GPU.",
            "Eligible slot wait requires observed dirty, configured and busy, expired deadline and no Wayland callback pending.",
            "Per-frame eligible wait belongs to the frame occupying the slot; aggregate gate time is independent of frame attribution.",
            "Native instrumentation runs only in generated source copies; a missing native hook produces null attribution.",
            "The timestamp query pair assumes one submission slot. A multi-slot experiment must allocate queries per slot.",
            "This probe does not verify pixels or measure physical input-to-display latency or whole-process allocations.",
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("raw", type=Path)
    parser.add_argument("--warmup", type=float, default=3.0)
    parser.add_argument("--duration", type=float)
    parser.add_argument("--workload", type=Path, help="Use the workload's actual start/finish boundaries")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    workload = json.loads(args.workload.read_text()) if args.workload else None
    result = summarize(json.loads(args.raw.read_text()), (args.warmup, args.duration), workload)
    text = json.dumps(result, indent=2) + "\n"
    if args.output:
        args.output.write_text(text)
    print(text)


if __name__ == "__main__":
    main()
