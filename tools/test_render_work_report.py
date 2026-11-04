import copy
import unittest

from render_work_report import analyze, counter_names


def census():
    counts = dict.fromkeys(counter_names(), 0)
    for key in ("commits", "passes", "surface_passes", "drawable_completions", "drawables", "presentation_callbacks", "positive_presentations"):
        counts[key] = 2
    return dict(version=1, complete=True, errors=0, clock="CLOCK_UPTIME_RAW",
                begin_ns=1000, end_ns=2000, queue_identity=10, layer_identity=11, counts=counts)


class RenderWorkReportTest(unittest.TestCase):
    def test_native_counts_do_not_claim_source_observation(self):
        result = analyze(census(), 2)
        self.assertEqual(result["per_input"]["commits"], 1)
        self.assertEqual(result["counts"]["terminal_sync"], 0)
        self.assertFalse(result["source_required"])
        with self.assertRaisesRegex(ValueError, "not connected"):
            analyze(census(), 2, require_source=True)

    def test_connected_source_counts_keep_extra_work(self):
        data = census()
        data["counts"].update(terminal_sync=4, terminal_rows=3)
        result = analyze(data, 2, require_source=True)
        self.assertEqual(result["per_input"]["terminal_sync"], 2)

    def test_negative_controls(self):
        controls = [
            ("Incomplete census", lambda data: data.update(complete=False)),
            ("Incomplete census", lambda data: data.update(version=True)),
            ("Counter errors", lambda data: data.update(errors=1)),
            ("Counter errors", lambda data: data.update(errors=False)),
            ("clock", lambda data: data.update(clock="ticks")),
            ("identity", lambda data: data.update(layer_identity=0)),
            ("Reversed", lambda data: data.update(end_ns=500)),
            ("schema", lambda data: data["counts"].pop("commits")),
            ("counter object", lambda data: data.update(counts=None)),
            ("counter value", lambda data: data["counts"].update(commits=-1)),
            ("counter value", lambda data: data["counts"].update(commits=True)),
            ("Metal4", lambda data: data["counts"].update(unsupported_metal4=1)),
            ("partition", lambda data: data["counts"].update(nil_drawables=1)),
            ("Missing", lambda data: data["counts"].update(commits=1)),
            ("Unclassified", lambda data: data["counts"].update(optical_hits=1)),
        ]
        for message, mutate in controls:
            with self.subTest(message=message):
                data = copy.deepcopy(census())
                mutate(data)
                with self.assertRaisesRegex(ValueError, message):
                    analyze(data, 2)


if __name__ == "__main__":
    unittest.main()
