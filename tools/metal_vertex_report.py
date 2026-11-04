"""Validate a private Qt Metal vertex-input census, without claiming timing wins."""

from render_work_report import analyze as analyze_render
from render_work_report import counter_names, require, unsigned


VERTEX_COUNTERS = (
    "vertex_input_calls",
    "vertex_input_changed",
    "vertex_input_unchanged",
    "vertex_input_bindings",
    "vertex_input_empty",
    "vertex_input_one",
    "vertex_input_buffer_changes",
    "vertex_input_offset_changes",
    "vertex_input_range_changes",
    "vertex_input_offset_only",
)


def analyze(census, measured_samples):
    require(isinstance(census, dict), "Invalid census object")
    counts = census.get("counts")
    require(isinstance(counts, dict), "Invalid counter object")
    base_names = counter_names()
    require(set(counts) == set(base_names) | set(VERTEX_COUNTERS), "Incomplete vertex counter schema")
    require(all(unsigned(value) for value in counts.values()), "Invalid vertex counter value")
    base = dict(census, counts={name: counts[name] for name in base_names})
    render = analyze_render(base, measured_samples)
    values = {name.removeprefix("vertex_input_"): counts[name] for name in VERTEX_COUNTERS}
    calls, changed = values["calls"], values["changed"]
    require(calls > 0, "Vertex source observer is not connected")
    require(changed + values["unchanged"] == calls, "Vertex call partition mismatch")
    require(values["empty"] + values["one"] <= calls, "Invalid vertex binding shapes")
    minimum_bindings = values["one"] + 2 * (calls - values["empty"] - values["one"])
    require(values["bindings"] >= minimum_bindings, "Invalid vertex binding total")
    buffers, offsets, ranges = (values[name] for name in ("buffer_changes", "offset_changes", "range_changes"))
    require(max(buffers, offsets, ranges) <= changed <= buffers + offsets + ranges,
            "Invalid vertex change union")
    offset_only = values["offset_only"]
    require(max(0, offsets - buffers - ranges) <= offset_only <= min(offsets, changed, calls - buffers, calls - ranges),
            "Invalid offset-only classification")
    return dict(
        scope="Measured-interval diagnostic calls, including work between inputs. Buffer/offset changes compare complete cached batches; range changes compare firstVertexBinding. No CPU attribution or timing acceptance.",
        measured_inputs=measured_samples,
        interval_ms=render["interval_ms"],
        counts=values,
        per_input={name: value / measured_samples for name, value in values.items()},
        unchanged_fraction=values["unchanged"] / calls,
        offset_only_fraction=offset_only / calls,
    )
