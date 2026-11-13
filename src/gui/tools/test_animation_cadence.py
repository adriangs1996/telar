#!/usr/bin/env python3
"""Keep native animation cadence accounting honest without opening a window."""

import unittest

from check_animation_cadence import summarize


class AnimationCadenceTest(unittest.TestCase):
    def report(self):
        return {"display": {"display_sync_enabled": True, "name": "Display"},
                "requested_screen": "Display", "mode": "tabs",
                "presentations": [{"cycle": 1, "value": index, "presented_seconds": 1 + index / 120}
                                  for index in range(4)]}

    def test_native_presentation_period(self):
        result = summarize(self.report(), 120)
        self.assertEqual(result["samples"], 3)
        self.assertAlmostEqual(result["p50_ms"], 1000 / 120)
        self.assertEqual(result["missed_refreshes"], 0)

    def test_discarded_drawable_remains_a_missed_refresh(self):
        report = self.report()
        report["presentations"][1]["presented_seconds"] = 0
        result = summarize(report, 120)
        self.assertEqual(result["discarded_drawables"], 1)
        self.assertEqual(result["missed_refreshes"], 1)
        self.assertAlmostEqual(result["longest_stall_ms"], 2000 / 120)

    def test_warmup_and_shutdown_are_outside_measurement(self):
        report = self.report()
        report["presentations"] += [{"cycle": cycle, "value": 0, "presented_seconds": 0} for cycle in (0, 13)]
        self.assertEqual(summarize(report, 120)["discarded_drawables"], 0)

    def test_repeated_positions_do_not_count_as_animation_changes(self):
        report = self.report()
        report["presentations"][1]["value"] = 0
        result = summarize(report, 120)
        self.assertEqual(result["samples"], 2)
        self.assertAlmostEqual(result["longest_stall_ms"], 2000 / 120)

    def test_wrong_display_or_disabled_sync_is_rejected(self):
        for field, value in (("name", "Other display"), ("display_sync_enabled", False)):
            with self.subTest(field=field):
                report = self.report()
                report["display"][field] = value
                with self.assertRaises(ValueError):
                    summarize(report, 120)

    def test_missing_positive_presentations_is_rejected(self):
        report = self.report()
        for frame in report["presentations"]:
            frame["presented_seconds"] = 0
        with self.assertRaises(ValueError):
            summarize(report, 120)

    def test_continuous_control_must_qualify_the_requested_rate(self):
        report = self.report()
        report["mode"] = "continuous"
        for index, frame in enumerate(report["presentations"]):
            frame["presented_seconds"] = 1 + index / 60
        with self.assertRaises(ValueError):
            summarize(report, 120)


if __name__ == "__main__":
    unittest.main()
