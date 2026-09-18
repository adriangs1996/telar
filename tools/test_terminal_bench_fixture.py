import unittest
from unittest.mock import patch

import gui_tui_latency
import terminal_bench_fixture as fixture


class FixtureToolsTest(unittest.TestCase):
    def test_repeat_preserves_original_bytes_and_chunk_size(self):
        for name in ('ascii', 'ansi'):
            chunks = fixture.payload_chunks(name, 'repeat', 2 * fixture.CHUNK_BYTES)
            self.assertEqual(chunks, (fixture.payload_chunk(name),) * 2)

    def test_variable_text_is_deterministic_with_distinct_fixed_length_lines(self):
        for name in ('ascii', 'ansi'):
            chunks = fixture.payload_chunks(name, 'variable', 2 * fixture.CHUNK_BYTES)
            self.assertEqual(chunks, fixture.payload_chunks(name, 'variable', 2 * fixture.CHUNK_BYTES))
            self.assertTrue(all(len(chunk) == fixture.CHUNK_BYTES for chunk in chunks))
            lines = [chunk[offset:offset + fixture.LINE_BYTES] for chunk in chunks
                     for offset in range(0, len(chunk), fixture.LINE_BYTES)]
            self.assertEqual(len(set(lines)), len(lines))
            self.assertTrue(all(line.endswith(b'\r\n') for line in lines))
            if name == 'ansi':
                self.assertTrue(all(line.startswith(b'\x1b[38;2;180;180;180m') and line.endswith(b'\x1b[0m\r\n')
                                    for line in lines))
            else:
                self.assertTrue(all(all(32 <= byte < 127 for byte in line[:-2]) for line in lines))

    def test_rate_rejects_invalid_or_unbounded_input(self):
        for value in ('nan', 'inf', '-inf', '0', '-1', '1e-300', '1025'):
            with self.assertRaises(ValueError):
                fixture.background_rate(value)
        self.assertIsNone(fixture.background_rate(None))
        self.assertEqual(fixture.background_rate('1.5'), 1.5)

    def test_pacer_drops_missed_slots_instead_of_recovering_in_a_burst(self):
        with (patch.object(fixture.time, 'monotonic', return_value=10) as clock,
              patch.object(fixture.time, 'sleep') as sleep):
            pacer = fixture.OutputPacer(1)
            interval = pacer.block_bytes / pacer.bytes_per_second
            clock.return_value = 11
            pacer.advance(pacer.block_bytes)
            self.assertAlmostEqual(pacer.deadline, 11 + interval)
            pacer.wait()
            sleep.assert_called_once()
            self.assertAlmostEqual(sleep.call_args.args[0], interval)

    def test_pacer_preserves_deadline_when_write_finishes_within_slot(self):
        with patch.object(fixture.time, 'monotonic', return_value=10) as clock:
            pacer = fixture.OutputPacer(1)
            interval = pacer.block_bytes / pacer.bytes_per_second
            clock.return_value = 10 + interval / 2
            pacer.advance(pacer.block_bytes)
            self.assertAlmostEqual(pacer.deadline, 10 + interval)

    def test_background_rate_validation_reports_backpressure_and_missing_evidence(self):
        row = dict(role='background', pid=7, background_progress=[
            dict(at_ns=1_000_000_000, emitted_bytes=1024 * 1024),
            dict(at_ns=2_000_000_000, emitted_bytes=2 * 1024 * 1024)])
        self.assertTrue(gui_tui_latency.background_load([row], 1)['rate_met'])
        row['background_progress'][-1]['at_ns'] = 3_000_000_000
        self.assertFalse(gui_tui_latency.background_load([row], 1)['rate_met'])
        row['background_progress'] = []
        self.assertFalse(gui_tui_latency.background_load([row], 1)['rate_met'])

    def test_rate_uses_two_complete_checkpoints_and_excludes_start_and_stop_fragments(self):
        row = dict(role='background', pid=7, background_started_ns=0,
                   background_last_write_ns=2_100_000_000, emitted_bytes=999999999,
                   background_progress=[dict(at_ns=1_000_000_000, emitted_bytes=123)])
        self.assertFalse(gui_tui_latency.background_load([row], 1)['rate_met'])
        row['background_progress'].append(dict(at_ns=2_000_000_000, emitted_bytes=123 + 1024 * 1024))
        result = gui_tui_latency.background_load([row], 1)
        self.assertTrue(result['rate_met'])
        self.assertEqual(result['fixtures'][0]['observed_mib_per_second'], [1])


if __name__ == '__main__':
    unittest.main()
