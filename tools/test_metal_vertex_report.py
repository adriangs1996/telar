import copy
import unittest

from metal_vertex_report import VERTEX_COUNTERS, analyze
from render_work_report import counter_names


def census():
    counts = dict.fromkeys(counter_names() + list(VERTEX_COUNTERS), 0)
    for name in ("commits", "passes", "surface_passes", "drawable_completions", "drawables", "presentation_callbacks", "positive_presentations"):
        counts[name] = 2
    values = dict(calls=5, changed=4, unchanged=1, bindings=7, empty=1, one=1,
                  buffer_changes=3, offset_changes=3, range_changes=1, offset_only=1)
    counts.update({"vertex_input_" + key: value for key, value in values.items()})
    return dict(version=1, complete=True, errors=0, clock="CLOCK_UPTIME_RAW",
                begin_ns=1000, end_ns=2000, queue_identity=10, layer_identity=11, counts=counts)


class MetalVertexReportTest(unittest.TestCase):
    def test_keeps_between_input_work_and_distinct_change_counts(self):
        report = analyze(census(), 2)
        self.assertEqual(report["per_input"]["calls"], 2.5)
        self.assertEqual(report["unchanged_fraction"], .2)
        self.assertEqual(report["offset_only_fraction"], .2)
        self.assertEqual(report["counts"]["buffer_changes"], 3)

    def test_rejects_malformed_or_disconnected_evidence(self):
        controls = [
            lambda c: c.update(complete=False),
            lambda c: c["counts"].pop("vertex_input_offset_only"),
            lambda c: c["counts"].update(unrecognized=1),
            lambda c: c["counts"].update(vertex_input_calls=True),
            lambda c: c["counts"].update(vertex_input_bindings=-1),
            lambda c: c["counts"].update({key: 0 for key in VERTEX_COUNTERS}),
            lambda c: c["counts"].update(vertex_input_unchanged=0),
            lambda c: c["counts"].update(vertex_input_empty=5),
            lambda c: c["counts"].update(vertex_input_bindings=6),
            lambda c: c["counts"].update(vertex_input_buffer_changes=5),
            lambda c: c["counts"].update(vertex_input_buffer_changes=0, vertex_input_offset_changes=0),
            lambda c: c["counts"].update(vertex_input_offset_only=3),
            lambda c: c["counts"].update(vertex_input_buffer_changes=0, vertex_input_range_changes=0,
                                       vertex_input_offset_changes=4, vertex_input_offset_only=1),
        ]
        for index, mutate in enumerate(controls):
            with self.subTest(index=index):
                data = copy.deepcopy(census())
                mutate(data)
                with self.assertRaises(ValueError):
                    analyze(data, 2)


if __name__ == "__main__":
    unittest.main()
