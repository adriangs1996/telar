import re
import unittest

from tui_bench_trace import Trace, changed_rows, row_text


class Screen:
    """Small independent interpreter for this fixture's emitted CSI subset."""

    def __init__(self, columns, rows):
        self.columns, self.rows = columns, rows
        self.cells = [[" "] * columns for _ in range(rows)]
        self.x = self.y = 0

    def feed(self, data):
        text = data.decode("ascii")
        index = 0
        while index < len(text):
            if text[index] == "\x1b":
                match = re.match(r"\x1b\[([?0-9;]*)([A-Za-z])", text[index:])
                if not match:
                    raise ValueError("Unsupported escape")
                args, final = match.groups()
                if final == "H":
                    values = [int(v) if v else 1 for v in args.split(";")]
                    self.y, self.x = (values + [1])[:2]
                    self.y -= 1
                    self.x -= 1
                elif final == "J" and args == "2" or final == "h" and args == "?1049":
                    self.cells = [[" "] * self.columns for _ in range(self.rows)]
                elif final not in ("m", "h", "l"):
                    raise ValueError("Unsupported CSI")
                index += len(match[0])
            else:
                self.cells[self.y][self.x] = text[index]
                self.x = min(self.columns - 1, self.x + 1)
                index += 1

    def marker(self):
        self.cells[min(7, self.rows - 1)][min(19, self.columns - 1)] = " "

    def text(self):
        return "\n".join("".join(row) for row in self.cells)


class TuiTraceTest(unittest.TestCase):
    def test_full_partial_resets_and_final_text(self):
        for columns, rows in ((1, 1), (39, 19), (82, 21), (120, 40)):
            trace, screen = Trace(), Screen(columns, rows)
            for sequence in range(97):
                screen.feed(trace.draw(columns, rows, sequence))
                screen.marker()
                self.assertEqual(screen.text(), trace.receipt()["expected_text"])
                self.assertEqual(trace.receipt()["sequence"], sequence)
            self.assertEqual(trace.screen_resets, 4)
            self.assertGreater(trace.partial_updates, trace.full_updates)

    def test_partial_updates_leave_other_rows_unchanged(self):
        trace = Trace()
        trace.draw(82, 21, 0)
        trace.draw(82, 21, 1)
        epochs = trace.receipt()["row_epochs"]
        self.assertEqual([i for i, epoch in enumerate(epochs) if epoch == 1], list(changed_rows(21, 1)))
        self.assertEqual(sum(epoch == 0 for epoch in epochs), 16)

    def test_capture_cell_survives_until_its_row_is_replaced(self):
        trace, screen = Trace(), Screen(82, 21)
        for sequence, capture in ((0, True), (1, False), (2, False), (3, False), (4, False)):
            screen.feed(trace.draw(82, 21, sequence, capture))
            screen.marker()
            self.assertEqual(screen.text(), trace.receipt()["expected_text"])
            self.assertEqual(trace.receipt()["expected_text"][0], "c" if sequence < 4 else "0")

    def test_resize_reinitializes_every_row(self):
        trace = Trace()
        trace.draw(39, 19, 0)
        trace.draw(39, 19, 1)
        screen = Screen(82, 21)
        screen.feed(trace.draw(82, 21, 2))
        screen.marker()
        self.assertEqual(screen.text(), trace.receipt()["expected_text"])
        self.assertEqual(trace.receipt()["row_epochs"], [2] * 21)

    def test_corrupted_payload_does_not_match_receipt(self):
        trace, screen = Trace(), Screen(82, 21)
        payload = trace.draw(82, 21, 0)
        original = row_text(82, 3, 0).encode()
        self.assertIn(original, payload)
        screen.feed(payload.replace(original, b"!" * len(original)))
        screen.marker()
        self.assertNotEqual(screen.text(), trace.receipt()["expected_text"])

    def test_invalid_dimensions_and_sequences(self):
        for values in ((0, 1, 0), (1, 0, 0), (2001, 1, 0), (1, 2001, 0), (1, 1, -1), (1, 1, 1000000)):
            with self.subTest(values=values), self.assertRaises(ValueError):
                Trace().draw(*values)


if __name__ == "__main__":
    unittest.main()
