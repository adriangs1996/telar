#!/usr/bin/env python3
"""Keep the startup statistics honest without building the probe."""

from pathlib import Path
import stat
import sys
import tempfile
import unittest

from measure_startup import measure, median_interval


class MedianIntervalTest(unittest.TestCase):
    def test_bounds_are_the_binomial_order_statistics(self):
        # For 40 samples, P(X <= 13) = 0.019 and P(X <= 14) = 0.040 with X ~ B(40, 1/2).
        self.assertEqual(median_interval(range(1, 41)), [14, 27])

    def test_too_few_samples_have_no_interval(self):
        # Even the extremes bound the median of five samples with less than 95%.
        self.assertIsNone(median_interval(range(5)))

    def test_order_of_samples_does_not_matter(self):
        self.assertEqual(median_interval(range(40, 0, -1)), [14, 27])


class MeasureTest(unittest.TestCase):
    def probe(self, directory, name, delay_ms):
        path = Path(directory) / name
        path.write_text(f'''#!{sys.executable}
import time
now = time.time_ns()
print('a Qt warning')
print('{{"main_ns":%d,"application_ns":%d,"controller_ns":%d,"root_ns":%d,"frame_ns":%d}}'
      % (now, now, now, now + {delay_ms} * 1_000_000, now + {delay_ms + 1} * 1_000_000))
''')
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        return path

    def test_every_probe_runs_each_round_and_compares_with_the_first(self):
        with tempfile.TemporaryDirectory() as directory:
            fast = self.probe(directory, 'fast', 10)
            slow = self.probe(directory, 'slow', 210)
            result = measure([fast, slow], 6, 0)

        self.assertEqual(len(result['probes']), 2)
        self.assertNotIn('against_first', result['probes'][0])
        comparison = result['probes'][1]['against_first']
        self.assertGreater(comparison['qml']['median_difference'], 150)
        self.assertEqual(comparison['qml']['faster_rounds'], 0)
        self.assertGreaterEqual(result['probes'][0]['frame']['minimum'], result['probes'][0]['root']['minimum'])

    def test_a_failing_probe_stops_the_measurement(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'failing'
            path.write_text(f'#!{sys.executable}\nraise SystemExit(3)\n')
            path.chmod(path.stat().st_mode | stat.S_IXUSR)
            with self.assertRaises(RuntimeError):
                measure([path], 1, 0)


if __name__ == '__main__':
    unittest.main()
