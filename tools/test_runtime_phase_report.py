import copy
import unittest

from runtime_phase_report import summarize


def snapshot(second, ticks):
    return dict(pid=42, before_ns=second * 10**9, after_ns=(second + 1) * 10**9,
                timebase_numer=125, timebase_denom=3, start_abstime=1, exit_abstime=0,
                uuid='12' * 16, user_ticks=ticks, system_ticks=ticks,
                idle_wakeups=ticks, interrupt_wakeups=ticks, pageins=ticks,
                resident_bytes=1000, footprint_bytes=800, lifetime_max_footprint_bytes=900,
                instructions=ticks * 100, cycles=ticks * 50)


class RuntimePhaseTests(unittest.TestCase):
    def setUp(self):
        self.outer = dict(errors=[], cleanup=dict(cleanup_complete=True), identity=dict(pid=42),
                          start=snapshot(1, 10), end=snapshot(90, 100))
        self.phase = dict(ready_ca_before=9.5, ready_ca_after=11.5, start_ca_before=19.5, start_ca_after=21.5, end_ca_before=79.5,
                          end_ca_after=81.5, snapshots=[snapshot(10, 20), snapshot(20, 30), snapshot(80, 80)])
        self.result = dict(failed=0, scroll_validation=dict(passed=True), warmup=2, summary=dict(n=2),
                           scroll_samples=[dict(input_at=a, presented_at=b) for a, b in [(12, 14), (18, 19), (30, 40), (60, 70)]])

    def test_additive_phases_and_mach_timebase(self):
        report = summarize(self.outer, self.phase, self.result)
        self.assertAlmostEqual(report['measured_cpu_fraction'], 50 / 90)
        self.assertAlmostEqual(report['phases']['measured_inputs']['user_cpu_seconds'], 50 * 125 / 3 / 1e9)
        self.assertEqual(report['phases']['measured_inputs']['instructions'], 5000)
        self.assertEqual(report['measured_inputs'], 2)

    def test_identity_counter_and_outer_window_rejections(self):
        for index in range(3):
            for key, value in dict(pid=43, uuid='34' * 16, start_abstime=2, timebase_numer=1,
                                   user_ticks=9, instructions=900, before_ns=1, exit_abstime=1).items():
                phase = copy.deepcopy(self.phase)
                phase['snapshots'][index][key] = value
                with self.subTest(index=index, key=key), self.assertRaises(ValueError):
                    summarize(self.outer, phase, self.result)

    def test_missing_reversed_and_nonfinite_phase(self):
        for key, value in dict(start_ca_before=22, start_ca_after=100, end_ca_before=15,
                               end_ca_after=float('nan')).items():
            with self.subTest(key=key), self.assertRaises(ValueError):
                summarize(self.outer, dict(self.phase, **{key: value}), self.result)
        with self.assertRaises(ValueError):
            summarize(self.outer, dict(self.phase, snapshots=[]), self.result)

    def test_action_coverage_and_failed_run(self):
        for index, key, value in [(0, 'input_at', 11), (1, 'presented_at', 20), (2, 'input_at', 21), (3, 'presented_at', 80),
                                  (2, 'input_at', float('inf')), (3, 'input_at', 35)]:
            result = copy.deepcopy(self.result)
            result['scroll_samples'][index][key] = value
            with self.subTest(index=index, key=key), self.assertRaises(ValueError):
                summarize(self.outer, self.phase, result)
        for key, value in dict(failed=1, warmup=0, summary=dict(n=3), scroll_validation=dict(passed=False)).items():
            with self.subTest(key=key), self.assertRaises(ValueError):
                summarize(self.outer, self.phase, dict(self.result, **{key: value}))


if __name__ == '__main__':
    unittest.main()
