"""Validate a diagnostic legacy-Metal census; never infer acceptance timing."""

from pathlib import Path
import re


def counter_names():
    names = re.findall(r"^  (render_work_[a-z0-9_]+),?$", Path(__file__).with_name("render_work_census.h").read_text(), re.M)
    if not names or names.pop() != "render_work_count":
        raise ValueError("Counter schema changed")
    return [name.removeprefix("render_work_") for name in names]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def unsigned(value):
    return isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= (1 << 64) - 1


def analyze(census, measured_samples, require_source=False):
    require(unsigned(measured_samples) and measured_samples > 0, "Invalid input count")
    require(isinstance(census, dict), "Invalid census object")
    require(unsigned(census.get("version")) and census["version"] == 1 and census.get("complete") is True, "Incomplete census")
    require(unsigned(census.get("errors")) and census["errors"] == 0, "Counter errors")
    require(census.get("clock") == "CLOCK_UPTIME_RAW", "Invalid census clock")
    for key in ("begin_ns", "end_ns", "queue_identity", "layer_identity"):
        require(unsigned(census.get(key)) and census[key] > 0, "Invalid census identity or boundary")
    require(census["end_ns"] > census["begin_ns"], "Reversed census boundaries")
    counts = census.get("counts", {})
    require(isinstance(counts, dict), "Invalid counter object")
    require(set(counts) == set(counter_names()), "Incomplete counter schema")
    require(all(unsigned(value) for value in counts.values()), "Invalid counter value")
    require(counts["unsupported_metal4"] == 0, "Unsupported Metal4 workload")
    for total, left, right in (("passes", "surface_passes", "offscreen_passes"),
                               ("drawable_completions", "drawables", "nil_drawables"),
                               ("presentation_callbacks", "positive_presentations", "zero_presentations")):
        require(counts[total] == counts[left] + counts[right], "Counter partition mismatch")
    for key in ("commits", "passes", "surface_passes", "drawables", "positive_presentations"):
        require(counts[key] >= measured_samples, "Missing measured render work")
    require(counts["standard_requests"] == counts["standard_hits"] + counts["standard_rasters"], "Unclassified standard request")
    require(counts["optical_requests"] == counts["optical_hits"] + counts["optical_rasters"] + counts["optical_reuses"], "Unclassified optical request")
    if require_source:
        require(counts["terminal_sync"] >= measured_samples and counts["terminal_rows"] >= measured_samples, "Source census not connected")
    return dict(scope="Diagnostic hook counts, including work between inputs. Callback counts are not display cadence; render passes are not draw calls. No causal or acceptance timing claim.",
                measured_inputs=measured_samples, source_required=require_source,
                interval_ms=(census["end_ns"] - census["begin_ns"]) / 1e6,
                counts=counts, per_input={key: value / measured_samples for key, value in counts.items()})


SEQUENCE_CAPACITY = 513


def analyze_sequences(census, warmup, measured_samples):
    report = analyze(census, measured_samples)
    require(unsigned(warmup), "Invalid warmup count")
    sequences = census.get("commits_by_sequence")
    require(isinstance(sequences, list) and len(sequences) == SEQUENCE_CAPACITY,
            "Missing or invalid sequence table")
    require(all(unsigned(value) for value in sequences), "Invalid sequence count")
    total_samples = warmup + measured_samples
    require(total_samples < len(sequences), "Sequence range exceeds capacity")
    require(sum(sequences) == report["counts"]["commits"], "Sequence partition mismatch")
    require(not any(sequences[total_samples + 1:]), "Commit attributed after final input")
    measured = sequences[warmup + 1:total_samples + 1]
    require(all(value > 0 for value in measured), "Measured input has no commit")
    return dict(scope="Input epoch observed at commit entry, including inter-input work. "
                "This is not proof of which update caused the frame or what it displayed.",
                warmup=warmup, measured_inputs=measured_samples,
                before_first_measured_commits=sum(sequences[:warmup + 1]),
                samples=[dict(sequence=warmup + index + 1, commits=value)
                         for index, value in enumerate(measured)],
                extra_commits=sum(value - 1 for value in measured))
