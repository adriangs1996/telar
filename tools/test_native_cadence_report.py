import copy
import math
import unittest

from native_cadence_report import report


def fixture():
    samples = [dict(output_ticks=1_900_000_000 + i * 8_333_333,
                    refresh_period=8_333_333, time_scale=1_000_000_000, flags=7)
               for i in range(160)]
    events = [dict(sequence=i + 1, accepted_ns=1_900_000_000 + i * 1_000_000_000 // 240,
                   scheduled_ns=1_900_000_000 + i * 1_000_000_000 // 240) for i in range(300)]
    result = dict(endpoint='presented', presentation_clock='MTLDrawable.presentedTime',
                  presentation_ms=[20] * 20, presentation_drawable_ids=list(range(20)),
                  display_sync=dict(enabled=True, observed=True, disabled=False),
                  failed=0, setup_complete=True, display_id=1, geometry_epoch=0,
                  viewport=[1600, 1000], marker=[470, 383],
                  initial_presentation=dict(geometry_requested_at=.1, gpu_completed_at=.2,
                      presented_at=.3, setup_completed_at=.4, first_input_at=.5,
                      geometry_epoch=0, viewport=[1600, 1000], marker=[470, 383],
                      clock='MTLDrawable.presentedTime', drawable_id=0),
                  cadence=dict(window_start=2., window_end=3., overflow=0,
                      frames=[dict(sequence=25 + 2 * i, presented_at=2.001 + i / 120,
                                   verified=True, drawable_id=i + 20) for i in range(120)]),
                  cadence_display_reference=dict(status=0, sample_count=len(samples), capacity=8192,
                      requested_display_id=1, actual_display_id=1, window_display_id=1,
                      timebase_numer=1, timebase_denom=1, host_time_flag=1, video_time_flag=2,
                      video_period_flag=4, samples=samples))
    return result, dict(rate_hz=240, events=events)


class NativeCadenceReportTest(unittest.TestCase):
    def test_verified_content_and_clock_have_no_missing_opportunities(self):
        result, producer = fixture()
        summary = report(result, producer)
        self.assertTrue(summary['qualified_native_content'])
        self.assertTrue(summary['active_refresh_qualified'])
        self.assertEqual(summary['missed_refresh_opportunities_between_changes'], 0)

    def test_sixty_content_fps_is_reported_as_missing_half_the_opportunities(self):
        result, producer = fixture()
        result['cadence']['frames'] = result['cadence']['frames'][::2]
        summary = report(result, producer)
        self.assertTrue(summary['qualified_native_content'])
        self.assertAlmostEqual(summary['changed_per_second'], 60)
        self.assertEqual(summary['missed_refresh_opportunities_between_changes'], 59)

    def test_faults_do_not_qualify_as_native_content(self):
        original, producer = fixture()
        mutations = [lambda r: r['cadence']['frames'].clear(),
                     lambda r: r['cadence']['frames'][10].update(presented_at=0),
                     lambda r: r['cadence']['frames'][10].update(verified=False),
                     lambda r: r['cadence']['frames'][10].update(sequence=1),
                     lambda r: r['cadence']['frames'][10].update(drawable_id=20),
                     lambda r: r.update(endpoint='gpu', gpu_ms=[20] * 20),
                     lambda r: r['initial_presentation'].update(presented_at=0)]
        for index, mutate in enumerate(mutations):
            result = copy.deepcopy(original)
            mutate(result)
            with self.subTest(fault=index):
                self.assertFalse(report(result, producer)['qualified_native_content'])

    def test_producer_coverage_and_rate_are_independent_gates(self):
        result, producer = fixture()
        truncated = dict(producer, events=producer['events'][:264])
        self.assertFalse(report(result, truncated)['qualified_native_content'])
        wrong_rate = dict(producer, rate_hz=300)
        summary = report(result, wrong_rate)
        self.assertFalse(summary['qualified_native_content'])
        self.assertIn('5%', summary['error'])
        for value in (0, -1, math.nan, math.inf):
            with self.subTest(rate=value):
                self.assertFalse(report(result, dict(producer, rate_hz=value))['qualified_native_content'])

    def test_reference_failure_does_not_discard_valid_content(self):
        result, producer = fixture()
        result['cadence_display_reference']['samples'][60]['flags'] = 1
        summary = report(result, producer)
        self.assertTrue(summary['qualified_native_content'])
        self.assertFalse(summary['display_reference_qualified'])
        self.assertFalse(summary['active_refresh_qualified'])


if __name__ == '__main__':
    unittest.main()
