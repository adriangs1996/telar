import copy
import unittest

from render_work_report import SEQUENCE_CAPACITY, analyze_sequences
from test_render_work_report import census


def sequence_census():
    data = census()
    data['commits_by_sequence'] = [0] * SEQUENCE_CAPACITY
    data['commits_by_sequence'][1:3] = [1, 1]
    return data


class RenderSequenceReportTest(unittest.TestCase):
    def test_complete_partition_keeps_boundary_work(self):
        data = sequence_census()
        data['commits_by_sequence'][:4] = [1, 2, 1, 3]
        data['counts']['commits'] = 7
        result = analyze_sequences(data, 1, 2)
        self.assertEqual(result['before_first_measured_commits'], 3)
        self.assertEqual(result['extra_commits'], 2)
        self.assertEqual(result['samples'], [dict(sequence=2, commits=1), dict(sequence=3, commits=3)])

    def test_negative_controls(self):
        controls = [
            ('Incomplete census', lambda d: d.update(complete=False)),
            ('sequence table', lambda d: d.pop('commits_by_sequence')),
            ('sequence table', lambda d: d.update(commits_by_sequence=[1, 1])),
            ('sequence count', lambda d: d['commits_by_sequence'].__setitem__(1, True)),
            ('sequence count', lambda d: d['commits_by_sequence'].__setitem__(1, -1)),
            ('sequence count', lambda d: d['commits_by_sequence'].__setitem__(1, 2**64)),
            ('partition', lambda d: d['counts'].update(commits=3)),
            ('final input', lambda d: d['commits_by_sequence'].__setitem__(slice(1, 4), [1, 0, 1])),
            ('no commit', lambda d: d['commits_by_sequence'].__setitem__(slice(1, 3), [2, 0])),
        ]
        for message, change in controls:
            with self.subTest(message=message):
                data = copy.deepcopy(sequence_census())
                change(data)
                with self.assertRaisesRegex(ValueError, message):
                    analyze_sequences(data, 0, 2)

    def test_invalid_ranges(self):
        for warmup in (True, -1, 1.5):
            with self.assertRaisesRegex(ValueError, 'warmup'):
                analyze_sequences(sequence_census(), warmup, 2)
        with self.assertRaisesRegex(ValueError, 'capacity'):
            analyze_sequences(sequence_census(), 512, 2)


if __name__ == '__main__':
    unittest.main()
