"""Positive timing controls; no native window, GPU, runtime or workload is started.

Run: python3 -m unittest discover -s tools -p test_slot_probes.py
"""
import json
from pathlib import Path
import tempfile
import unittest

import gui_slot_probe
import linux_slot_summary


DIRTY, BUSY, CLOSED = 2, 4, 16
METAL_VISIBLE = 8
LINUX_CONFIGURED, WAYLAND_CALLBACK = 1, 8


def metal_event(kind, at_ms, data=(0, 0, 0)):
    return [kind, at_ms / 1000, *data]


def metal_state(kind, at_ms, state):
    deadline_ms, flags = state
    return metal_event(kind, at_ms, (0, deadline_ms / 1000, flags | 1))


def analyze_metal(events, window=None):
    trace = dict(dropped=0, viewport=[1900, 2112], events=events)
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "trace.json"
        path.write_text(json.dumps(trace))
        return gui_slot_probe.analyze(path, window)


def linux_event(kind, at_ms, data=(0, 0)):
    return [kind, round(at_ms * 1000000), *data]


def linux_state(at_ms, flags, deadline_ms=0):
    return linux_event(0, at_ms, (flags, round(deadline_ms * 1000000)))


def linux_raw(events, acquire_ms=1):
    start = round(acquire_ms * 1000000)
    frame = dict(
        acquire_begin=start, acquire_end=start + 100000,
        encode_begin=start + 200000, resources_end=start + 300000,
        encode_end=start + 400000, submit_begin=start + 500000,
        submit_end=start + 600000, present_begin=start + 700000,
        present_end=start + 800000, fence_begin=start + 900000,
        fence_end=start + 1000000, gpu_ticks=200000,
        present_fence_wait_ns=0, allocated_bytes=0, atlas_bytes=0,
        width=1900, height=2112, quads=100, image=0,
        acquired=0, submitted=0, presented=0, completed=0,
    )
    worker_events = [
        linux_event(1, acquire_ms - .4),
        linux_event(2, acquire_ms - .3, (1, 100)),
        linux_event(3, acquire_ms - .2, (1, 0)),
        linux_event(5, acquire_ms - .1, (1, 0)),
        linux_event(6, acquire_ms + 1.1, (1, 0)),
    ]
    return dict(
        frame_overflow=0, event_overflow=0, device="synthetic timing control",
        timestamp_period_ns=1, present_mode=2, swapchain_images=3,
        frames=[frame], events=events + worker_events,
    )


class StateFreshnessTests(unittest.TestCase):
    def report(self, frames):
        return dict(summary=dict(observation_start_s=.010, observation_end_s=.050), frames=frames)

    def test_repeated_state_ages_without_becoming_a_new_source_update(self):
        report = self.report({
            1: dict(prepare_at=.020, gpu_complete=.025, marker_sequence=2),
            2: dict(prepare_at=.030, gpu_complete=.035, marker_sequence=2),
            3: dict(prepare_at=.009, gpu_complete=.015, marker_sequence=1),
            4: dict(prepare_at=.045, gpu_complete=.051, marker_sequence=3),
        })
        result = gui_slot_probe.analyze_freshness(report, [[1, .001, .002], [2, .005, .007], [3, .040, .041]])
        self.assertEqual(result['unique_states'], 1)
        self.assertEqual(len(result['frames']), 2)
        self.assertAlmostEqual(result['metrics']['state_age_at_prepare_ms']['p50_ms'], 20)
        self.assertAlmostEqual(result['metrics']['state_age_at_completion_ms']['p50_ms'], 25)
        self.assertAlmostEqual(result['metrics']['source_write_ms']['p50_ms'], 2)

    def test_invalid_marker_or_source_clock_fails_instead_of_dropping_a_sample(self):
        for sequence, issued in ((None, .001), (3, .001), (1, .030)):
            with self.subTest(sequence=sequence, issued=issued):
                report = self.report({1: dict(prepare_at=.020, gpu_complete=.025, marker_sequence=sequence)})
                with self.assertRaises(ValueError):
                    gui_slot_probe.analyze_freshness(report, [[1, issued, issued + .001]])

    def test_marker_is_joined_to_the_submission_that_contains_it(self):
        report = self.report({
            1: dict(prepare_at=.015, gpu_complete=.017, marker_sequence=1),
            2: dict(prepare_at=.020, gpu_complete=.023, marker_sequence=3),
        })
        result = gui_slot_probe.analyze_freshness(report, [[1, .010, .011], [2, .014, .0145], [3, .019, .0195]])
        self.assertEqual(result['unique_states'], 2)
        self.assertAlmostEqual(result['frames'][0]['state_age_at_completion_ms'], 7)
        self.assertAlmostEqual(result['frames'][1]['state_age_at_completion_ms'], 4)


class MetalSlotTimingTests(unittest.TestCase):
    def test_deadline_partitions_known_wait_even_without_an_event_at_deadline(self):
        # Each row declares the occupied interval and its exact intersection
        # with [deadline, infinity), rather than deriving an expected percentile.
        cases = [
            (2, 9, 10, 7, 0),
            (2, 15, 10, 13, 5),
            (12, 17, 10, 5, 5),
            (2, 10, 10, 8, 0),
        ]
        for request, complete, deadline, total, eligible in cases:
            with self.subTest(request=request, complete=complete):
                flags = METAL_VISIBLE | BUSY
                result = analyze_metal([
                    metal_state("measure_start", 0, (deadline, flags)),
                    metal_state("request_begin", request, (deadline, flags)),
                    metal_event("complete_begin", complete, (1, 1, 0)),
                    metal_event("complete_end", complete + 3, (1, 1, 0)),
                    metal_state("close_end", complete + 5, (deadline, CLOSED)),
                ])["summary"]
                self.assertAlmostEqual(result["dirty_busy_ms_total"], total)
                self.assertAlmostEqual(result["dirty_eligible_busy_ms_total"], eligible)

    def test_repeated_requests_and_gpu_feedback_do_not_duplicate_or_release_wait(self):
        flags = METAL_VISIBLE | BUSY
        dirty = flags | DIRTY
        result = analyze_metal([
            metal_state("measure_start", 0, (10, flags)),
            metal_state("request_begin", 2, (10, flags)),
            metal_state("request_end", 2, (10, dirty)),
            metal_state("request_begin", 4, (10, dirty)),
            metal_state("request_end", 4, (10, dirty)),
            metal_state("ready_begin", 7, (10, dirty)),
            metal_state("ready_end", 7, (10, dirty)),
            metal_event("gpu_complete", 11, (1, 1, 0)),
            metal_event("complete_begin", 15, (1, 1, 0)),
            metal_event("complete_end", 18, (1, 1, 0)),
            metal_event("prepare_begin", 20),
            metal_event("prepare_end", 21, (2, 100, 0)),
            metal_state("close_end", 25, (10, CLOSED)),
        ])
        self.assertAlmostEqual(result["summary"]["dirty_busy_ms_total"], 13)
        self.assertAlmostEqual(result["summary"]["dirty_eligible_busy_ms_total"], 5)
        self.assertEqual(result["summary"]["requests"], 2)
        self.assertAlmostEqual(result["frames"][2]["dirty_busy_ms"], 13)
        self.assertAlmostEqual(result["frames"][2]["eligible_busy_ms"], 5)
        self.assertAlmostEqual(result["frames"][2]["request_to_prepare_ms"], 18)

    def test_clean_busy_and_dirty_free_states_are_not_slot_wait(self):
        for flags in (METAL_VISIBLE | BUSY, METAL_VISIBLE | DIRTY):
            with self.subTest(flags=flags):
                result = analyze_metal([
                    metal_state("measure_start", 0, (0, flags)),
                    metal_state("close_end", 20, (0, CLOSED)),
                ])["summary"]
                self.assertEqual(result["dirty_busy_ms_total"], 0)
                self.assertEqual(result["dirty_eligible_busy_ms_total"], 0)

    def test_hidden_and_closed_intervals_do_not_count(self):
        dirty = DIRTY | BUSY
        result = analyze_metal([
            metal_state("measure_start", 0, (0, dirty)),
            metal_state("ready_begin", 3, (0, dirty | METAL_VISIBLE)),
            metal_state("ready_end", 7, (0, dirty)),
            metal_state("ready_begin", 10, (0, dirty | METAL_VISIBLE)),
            metal_event("close_begin", 13),
            metal_state("close_end", 20, (0, CLOSED)),
        ])["summary"]
        # Visible intervals [3, 7) and [10, 13) contribute 4 + 3 ms.
        self.assertAlmostEqual(result["dirty_busy_ms_total"], 7)
        self.assertAlmostEqual(result["dirty_eligible_busy_ms_total"], 7)

    def test_clipping_replays_prior_state_and_clips_crossing_wait(self):
        flags = METAL_VISIBLE | BUSY
        events = [
            metal_state("measure_start", 0, (10, flags)),
            metal_state("request_begin", 2, (10, flags)),
            metal_event("complete_begin", 25, (1, 1, 0)),
            metal_state("close_end", 30, (10, CLOSED)),
        ]
        result = analyze_metal(events, (.004, .018))["summary"]
        self.assertAlmostEqual(result["elapsed_seconds"], .014)
        self.assertAlmostEqual(result["dirty_busy_ms_total"], 14)
        self.assertAlmostEqual(result["dirty_eligible_busy_ms_total"], 8)
        self.assertEqual(result["requests"], 0)
        self.assertAlmostEqual(result["dirty_eligible_busy_percent"], 100 * 8 / 14)

    def test_phase_samples_require_both_endpoints_inside_observation(self):
        result = analyze_metal([
            metal_state("measure_start", 0, (0, METAL_VISIBLE)),
            metal_event("prepare_begin", 6),
            metal_event("prepare_end", 8, (1, 100, 0)),
            metal_event("prepare_begin", 10),
            metal_event("prepare_end", 11, (2, 100, 0)),
            metal_event("prepare_begin", 14),
            metal_event("prepare_end", 16, (3, 100, 0)),
            metal_state("close_end", 20, (0, CLOSED)),
        ], (.007, .015))
        self.assertEqual(len(result["samples"]["prepare_ms"]), 1)
        self.assertAlmostEqual(result["samples"]["prepare_ms"][0], 1)
        self.assertEqual(result["summary"]["frames_prepared"], 2)
        self.assertEqual(result["summary"]["prepared_frames_excluded_from_latency"], 2)

    def test_feedback_before_start_marker_is_not_part_of_measurement(self):
        result = analyze_metal([
            metal_event("gpu_complete", 1, (99, 0, 0)),
            metal_state("measure_start", 2, (0, METAL_VISIBLE | DIRTY | BUSY)),
            metal_event("complete_begin", 5, (100, 1, 0)),
            metal_state("close_end", 8, (0, CLOSED)),
        ])["summary"]
        self.assertAlmostEqual(result["dirty_busy_ms_total"], 3)
        self.assertAlmostEqual(result["elapsed_seconds"], .006)
        self.assertEqual(result["failed_gpu"], 0)

    def test_gpu_and_callback_delays_are_correlated_per_token(self):
        events = [metal_state("measure_start", 0, (0, METAL_VISIBLE))]
        timings = [(1, 2, 3, 10, 11), (20, 21, 31, 32, 52), (60, 65, 66, 67, 68)]
        for token, (commit, gpu_start, gpu_end, feedback, main) in enumerate(timings, 1):
            events += [
                metal_event("prepare_begin", commit - .5),
                metal_event("prepare_end", commit - .25, (token, 100, 0)),
                metal_event("wait_begin", commit - .1, (token, 0, 0)),
                metal_event("commit_begin", commit, (token, 1, 0)),
                metal_event("gpu_complete", feedback, (token, 1, 0)),
                metal_event("gpu_start", feedback, (token, gpu_start / 1000, 0)),
                metal_event("gpu_end", feedback, (token, gpu_end / 1000, 0)),
                metal_event("complete_begin", main, (token, 1, 0)),
            ]
        events.append(metal_state("close_end", 70, (0, CLOSED)))
        result = analyze_metal(events)
        self.assertEqual(len(result["samples"]["gpu_end_to_feedback_ms"]), 3)
        self.assertEqual(len(result["samples"]["feedback_to_main_ms"]), 3)
        self.assertAlmostEqual(result["summary"]["metrics"]["gpu_end_to_feedback_ms"]["p50_ms"], 1)
        for actual, expected in zip(result["samples"]["gpu_end_to_feedback_ms"], (7, 1, 1)):
            self.assertAlmostEqual(actual, expected)
        for actual, expected in zip(result["samples"]["feedback_to_main_ms"], (1, 20, 1)):
            self.assertAlmostEqual(actual, expected)
        # Subtracting median GPU and queue durations from median submit-to-feedback
        # would incorrectly report 7 ms here instead of the measured 1 ms median.
        self.assertAlmostEqual(result["summary"]["metrics"]["submit_to_feedback_ms"]["p50_ms"], 9)


class VulkanSlotTimingTests(unittest.TestCase):
    def test_deadline_partitions_known_wait_even_without_an_event_at_deadline(self):
        cases = [(2, 9, 7, 0), (2, 15, 13, 5), (12, 17, 5, 5), (2, 10, 8, 0)]
        for request, complete, total, eligible in cases:
            with self.subTest(request=request, complete=complete):
                events = [
                    linux_state(0, LINUX_CONFIGURED | BUSY, 10),
                    linux_state(request, LINUX_CONFIGURED | DIRTY | BUSY, 10),
                    linux_event(4, complete, (1, 0)),
                    linux_state(complete + 3, LINUX_CONFIGURED | DIRTY, 10),
                    linux_state(complete + 5, CLOSED, 10),
                    linux_event(7, complete + 5),
                ]
                gate = linux_slot_summary.summarize(linux_raw(events), (0, None))["gates"]
                self.assertEqual(gate["dirty_busy_ns"], total * 1000000)
                self.assertEqual(gate["eligible_slot_wait_ns"], eligible * 1000000)
                self.assertEqual(gate["dirty_busy_deadline_ns"], (total - eligible) * 1000000)

    def test_clean_busy_and_dirty_free_states_are_not_slot_wait(self):
        for flags in (LINUX_CONFIGURED | BUSY, LINUX_CONFIGURED | DIRTY, DIRTY | BUSY):
            with self.subTest(flags=flags):
                raw = linux_raw([linux_state(0, flags), linux_state(20, CLOSED), linux_event(7, 20)])
                gate = linux_slot_summary.summarize(raw, (0, None))["gates"]
                self.assertEqual(gate["dirty_busy_ns"], 0)
                self.assertEqual(gate["eligible_slot_wait_ns"], 0)

    def test_wayland_callback_and_deadline_waits_are_not_double_counted(self):
        dirty = LINUX_CONFIGURED | DIRTY | BUSY
        raw = linux_raw([
            linux_state(0, LINUX_CONFIGURED | BUSY, 10),
            linux_state(2, dirty | WAYLAND_CALLBACK, 10),
            linux_state(8, dirty, 10),
            linux_event(4, 20, (1, 0)),
            linux_state(25, CLOSED, 10),
            linux_event(7, 25),
        ])
        gate = linux_slot_summary.summarize(raw, (0, None))["gates"]
        # [2,8): callback; [8,10): deadline; [10,20): slot alone.
        self.assertEqual(gate["dirty_busy_ns"], 18000000)
        self.assertEqual(gate["dirty_busy_callback_ns"], 6000000)
        self.assertEqual(gate["dirty_busy_deadline_ns"], 2000000)
        self.assertEqual(gate["eligible_slot_wait_ns"], 10000000)

    def test_repeated_snapshots_and_worker_done_do_not_release_native_slot(self):
        dirty = LINUX_CONFIGURED | DIRTY | BUSY
        raw = linux_raw([
            linux_state(0, LINUX_CONFIGURED | BUSY, 10),
            linux_state(2, dirty, 10),
            linux_state(4, dirty, 10),
            linux_state(4, dirty, 10),
            linux_state(7, dirty, 10),
            linux_event(4, 15, (1, 0)),
            linux_state(18, LINUX_CONFIGURED | DIRTY, 10),
            linux_state(25, CLOSED, 10),
            linux_event(7, 25),
        ])
        result = linux_slot_summary.summarize(raw, (0, None))
        # The worker ends at 2.1 ms; its completion is consumed only at 15 ms.
        self.assertEqual(result["gates"]["dirty_busy_ns"], 13000000)
        self.assertEqual(result["gates"]["eligible_slot_wait_ns"], 5000000)
        self.assertAlmostEqual(result["metrics"]["main_completion_delay_ms"]["p50"], 12.9)
        self.assertAlmostEqual(result["metrics"]["occupied_frame_eligible_slot_wait_ms"]["p50"], 5)

    def test_closed_state_stops_accumulating_before_final_snapshot(self):
        dirty = LINUX_CONFIGURED | DIRTY | BUSY
        raw = linux_raw([
            linux_state(0, LINUX_CONFIGURED | BUSY),
            linux_state(2, dirty),
            linux_state(7, dirty | CLOSED),
            linux_state(20, CLOSED),
            linux_event(7, 20),
        ])
        gate = linux_slot_summary.summarize(raw, (0, None))["gates"]
        self.assertEqual(gate["dirty_busy_ns"], 5000000)
        self.assertEqual(gate["eligible_slot_wait_ns"], 5000000)

    def test_workload_clipping_preserves_prior_state_and_crossing_deadline(self):
        dirty = LINUX_CONFIGURED | DIRTY | BUSY
        raw = linux_raw([
            linux_state(0, LINUX_CONFIGURED | BUSY, 10),
            linux_state(2, dirty, 10),
            linux_event(4, 25, (1, 0)),
            linux_state(30, CLOSED, 10),
            linux_event(7, 30),
        ], acquire_ms=8)
        workload = dict(started_monotonic_s=0, finished_monotonic_s=.018)
        result = linux_slot_summary.summarize(raw, (.004, .05), workload)
        self.assertEqual(result["start_ns"], 4000000)
        self.assertEqual(result["end_ns"], 18000000)
        self.assertEqual(result["gates"]["dirty_busy_ns"], 14000000)
        self.assertEqual(result["gates"]["dirty_busy_deadline_ns"], 6000000)
        self.assertEqual(result["gates"]["eligible_slot_wait_ns"], 8000000)

    def test_shutdown_clips_selected_duration(self):
        dirty = LINUX_CONFIGURED | DIRTY | BUSY
        raw = linux_raw([
            linux_state(0, LINUX_CONFIGURED | BUSY, 10),
            linux_state(2, dirty, 10),
            linux_state(18, dirty, 10),
            linux_event(7, 18),
            linux_state(30, CLOSED, 10),
        ], acquire_ms=8)
        workload = dict(started_monotonic_s=0, finished_monotonic_s=.05)
        result = linux_slot_summary.summarize(raw, (.004, .03), workload)
        self.assertEqual(result["end_ns"], 18000000)
        self.assertEqual(result["gates"]["dirty_busy_ns"], 14000000)
        self.assertEqual(result["gates"]["eligible_slot_wait_ns"], 8000000)


if __name__ == "__main__":
    unittest.main()
