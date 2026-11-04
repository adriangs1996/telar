import copy
import hashlib
import math
import re
import unittest

from scroll_bench_fixture import CORPUS_ROWS, corpus, corpus_row
from scroll_bench_report import validate_scroll


def example():
    payload = corpus(82)
    receipt = dict(version=1, phase='ready', pid=123, cols=82, rows=21,
                   initial_top_row=4076, rows_per_input=3, corpus_rows=CORPUS_ROWS,
                   geometry_generation=3, payload_bytes=len(payload),
                   payload_sha256=hashlib.sha256(payload).hexdigest())
    result = dict(interaction='scroll_up', endpoint='presented', input_method='native_discrete_wheel',
                  warmup=2, pty_cells=[82, 21], scroll_initial_top_row=4076,
                  scroll_rows_per_input=3, presentation_ms=[25.] * 5,
                  scroll_samples=[dict(expected_row=4076 - 3 * index, observed_row=4076 - 3 * index,
                                       input_at=float(index), presented_at=index + .025)
                                  for index in range(1, 6)])
    return result, receipt


class ScrollBenchTest(unittest.TestCase):
    def test_corpus_rows_do_not_wrap_and_have_distinct_identities(self):
        for columns in (48, 82, 120):
            rows = corpus(columns).split(b'\r\n')
            self.assertEqual(len(rows), CORPUS_ROWS)
            for identity, row in enumerate(rows, 1):
                text = re.sub(rb'\x1b\[[0-9;]*m', b'', row)
                self.assertEqual(len(text), columns - 1)
                self.assertEqual(text[:27], b' ' * 27)
                self.assertTrue(text[27:].startswith(f' row {identity:04d} '.encode()))
                colors = re.findall(rb'\x1b\[48;2;(\d+);(\d+);(\d+)m', row)
                self.assertEqual(len(colors), 8)
                self.assertEqual(colors[0], (b'230', b'20', b'60'))
                encoded = 0
                for red, green, blue in colors[2:6]:
                    self.assertEqual(red, green)
                    self.assertEqual(red, blue)
                    self.assertEqual((int(red) - 8) % 16, 0)
                    encoded = (encoded << 4) | ((int(red) - 8) // 16)
                self.assertEqual(encoded, identity)

    def test_invalid_inputs(self):
        for identity, columns in [(0, 82), (4097, 82), (True, 82), (1, 47), (1, 2001), (1, 82.5)]:
            with self.subTest(identity=identity, columns=columns), self.assertRaises(ValueError):
                corpus_row(identity, columns)

    def test_qualified_sequence(self):
        result, receipt = example()
        report = validate_scroll(result, receipt, 123)
        self.assertEqual(report['samples'], 3)
        self.assertEqual(report['final_top_row'], 4061)

    def test_rejects_incomplete_wrong_or_stale_observations(self):
        changes = [
            ('interaction', 'typing'), ('endpoint', 'gpu'), ('input_method', 'key'),
            ('warmup', True), ('warmup', 5), ('pty_cells', [82, 22]),
            ('scroll_initial_top_row', 4075), ('scroll_rows_per_input', 1),
            ('presentation_ms', []), ('scroll_samples', []),
        ]
        for field, value in changes:
            result, receipt = example()
            result[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_scroll(result, receipt, 123)
        for field, value in [('observed_row', 4076), ('expected_row', 4076),
                             ('observed_row', True), ('input_at', math.nan),
                             ('presented_at', 0), ('presented_at', 1.026)]:
            result, receipt = example()
            result['scroll_samples'][0][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                validate_scroll(result, receipt, 123)
        result, receipt = example()
        result['scroll_samples'][2] = copy.deepcopy(result['scroll_samples'][1])
        with self.assertRaises(ValueError):
            validate_scroll(result, receipt, 123)

    def test_rejects_wrong_fixture(self):
        for field, value in [('pid', 124), ('pid', True), ('version', 2), ('version', True), ('phase', 'failed'),
                             ('rows', 22), ('cols', 47), ('corpus_rows', 4000),
                             ('initial_top_row', 4075), ('payload_bytes', 4),
                             ('payload_sha256', '0' * 64), ('geometry_generation', 0)]:
            result, receipt = example()
            receipt[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_scroll(result, receipt, 123)


if __name__ == '__main__':
    unittest.main()
