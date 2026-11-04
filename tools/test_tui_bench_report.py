import copy
import unittest

from tui_bench_report import validate_screen
from tui_bench_trace import Trace


def receipt():
    trace = Trace()
    for sequence in range(44):
        trace.draw(82, 21, sequence)
    result = trace.receipt()
    result.update(pid=100, pane_id=1, pane_generation=2)
    return result


class TuiReportTest(unittest.TestCase):
    def test_diagnostic_write_mode_is_preserved(self):
        trace = receipt()
        trace['write_mode'] = 'coalesced'
        self.assertEqual(validate_screen(trace, trace['expected_text'], 43)['write_mode'], 'coalesced')
        trace['write_mode'] = 'unknown'
        with self.assertRaisesRegex(ValueError, 'write mode'):
            validate_screen(trace, trace['expected_text'], 43)

    def test_exact_text_after_partial_updates(self):
        trace = receipt()
        for suffix in ("", "\n"):
            report = validate_screen(trace, trace["expected_text"] + suffix, 43)
            self.assertTrue(report["passed"])
            self.assertEqual(report["sequence"], 43)

    def test_missing_reordered_or_extra_content_is_rejected(self):
        trace = receipt()
        text = trace["expected_text"]
        lines = text.splitlines()
        for wrong in (text[:-1], text + "x", text + "\n\n", "\n".join(lines[1:]),
                      "\n".join(reversed(lines)), text.replace("000040", "000039")):
            self.assertNotEqual(wrong, text)
            with self.subTest(wrong=wrong[:20]), self.assertRaisesRegex(ValueError, "differs"):
                validate_screen(trace, wrong, 43)

    def test_invalid_or_stale_receipts_are_rejected(self):
        original = receipt()
        changes = dict(sequence=42, columns=True, rows=0, pid=0, pane_id=0,
                       pane_generation=False, body_bytes=0, workload="marker",
                       row_epochs=[40] * 21, capture_cell=True, expected_text="forged")
        for key, value in changes.items():
            data = copy.deepcopy(original)
            data[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_screen(data, original["expected_text"], 43)


if __name__ == "__main__":
    unittest.main()
