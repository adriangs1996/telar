import math
import unittest

from native_display_reference import classify_gaps, qualify_display


class IntervalClassificationTest(unittest.TestCase):
    def test_native_120_hz_intervals_have_no_missing_opportunities(self):
        self.assertEqual(classify_gaps([1 / 120] * 119, 1 / 120)['missed_refresh_opportunities_between_changes'], 0)

    def test_native_60_hz_on_a_120_hz_reference_misses_every_other_opportunity(self):
        self.assertEqual(classify_gaps([1 / 60] * 59, 1 / 120)['missed_refresh_opportunities_between_changes'], 59)

    def test_three_period_stall_counts_two_missing_opportunities(self):
        self.assertEqual(classify_gaps([1 / 120, 3 / 120, 1 / 120], 1 / 120)['missed_refresh_opportunities_between_changes'], 2)

    def test_unknown_or_invalid_intervals_fail(self):
        for gap in (0, -1, math.nan, math.inf, .010):
            with self.subTest(gap=gap), self.assertRaises(ValueError):
                classify_gaps([gap], 1 / 120)


def reference_fixture():
    period_ticks = 8_333_333
    samples = [dict(output_ticks=1_000_000_000 + i * period_ticks,
                    refresh_period=period_ticks, time_scale=1_000_000_000, flags=7)
               for i in range(123)]
    frames = [dict(sequence=i + 1, presented_at=s['output_ticks'] / 1e9)
              for i, s in enumerate(samples[1:-1])]
    return dict(display_id=1,
                cadence=dict(window_start=frames[0]['presented_at'],
                             window_end=samples[-1]['output_ticks'] / 1e9, frames=frames),
                cadence_display_reference=dict(status=0, sample_count=len(samples), capacity=8192,
                    requested_display_id=1, actual_display_id=1, window_display_id=1,
                    timebase_numer=1, timebase_denom=1, host_time_flag=1, video_time_flag=2,
                    video_period_flag=4, samples=samples))


class ReferencePhaseTest(unittest.TestCase):
    def test_invalid_reference_numbers_never_qualify(self):
        for field in ('refresh_period', 'time_scale'):
            for value in (0, -1, math.nan, math.inf):
                fixture = reference_fixture()
                fixture['cadence_display_reference']['samples'][60][field] = value
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    qualify_display(fixture)
        for field in ('timebase_numer', 'timebase_denom'):
            for value in (math.nan, math.inf):
                fixture = reference_fixture()
                fixture['cadence_display_reference'][field] = value
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    qualify_display(fixture)

    def test_invalid_windows_and_clock_flags_never_qualify(self):
        for start, end in ((0, 1), (2, 1), (1, 1), (math.nan, 2), (1, math.inf)):
            fixture = reference_fixture()
            fixture['cadence'].update(window_start=start, window_end=end)
            with self.subTest(start=start, end=end), self.assertRaises(ValueError):
                qualify_display(fixture)
        for value in (0, 2, 3, -1):
            fixture = reference_fixture()
            fixture['cadence_display_reference']['host_time_flag'] = value
            with self.subTest(flag=value), self.assertRaises(ValueError):
                qualify_display(fixture)

    def test_fixed_reference_and_native_presentation_qualify(self):
        result = qualify_display(reference_fixture())
        self.assertTrue(result['display_reference_qualified'])
        self.assertTrue(result['missed_refresh_classification_qualified'])
        self.assertEqual(result['missed_refresh_opportunities_between_changes'], 0)

    def test_short_phase_adjustment_does_not_hide_behind_median(self):
        fixture = reference_fixture()
        # Preserve the median, nominal video period and continuous reference
        # coverage while moving later host timestamps by a quarter period.
        for row in fixture['cadence_display_reference']['samples'][60:]:
            row['output_ticks'] -= 2_083_333
        fixture['cadence_display_reference']['samples'].append(dict(
            fixture['cadence_display_reference']['samples'][-1],
            output_ticks=fixture['cadence_display_reference']['samples'][-1]['output_ticks'] + 8_333_333))
        fixture['cadence_display_reference']['sample_count'] += 1
        with self.assertRaisesRegex(ValueError, 'cadence/phase'):
            qualify_display(fixture)

    def test_missing_reference_interval_is_not_a_native_stall(self):
        fixture = reference_fixture()
        del fixture['cadence_display_reference']['samples'][60]
        fixture['cadence_display_reference']['sample_count'] -= 1
        with self.assertRaisesRegex(ValueError, 'cadence/phase'):
            qualify_display(fixture)

    def test_native_phase_error_does_not_invalidate_a_fixed_reference(self):
        fixture = reference_fixture()
        for frame in fixture['cadence']['frames'][60:]:
            frame['presented_at'] += 1 / 240
        fixture['cadence']['frames'].pop()
        result = qualify_display(fixture)
        self.assertTrue(result['display_reference_qualified'])
        self.assertFalse(result['missed_refresh_classification_qualified'])

    def test_wrong_display_and_missing_clock_flags_fail(self):
        for key, value in [('window_display_id', 2), ('timebase_denom', 0)]:
            fixture = reference_fixture()
            fixture['cadence_display_reference'][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                qualify_display(fixture)
        fixture = reference_fixture()
        fixture['cadence_display_reference']['samples'][60]['flags'] = 1
        with self.assertRaises(ValueError):
            qualify_display(fixture)


if __name__ == '__main__':
    unittest.main()
