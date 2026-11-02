import json
import os
from pathlib import Path
import signal
import tempfile
import unittest
from unittest.mock import patch

import terminal_bench_fixture as benchmark


class FixtureResizeTest(unittest.TestCase):
    def test_capture_witness_keeps_the_latency_sequence_and_clears_on_input(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {}, clear=True):
            fixture = benchmark.Fixture(Path(directory))
            fixture.primary = True
            fixture.size = os.terminal_size((101, 46))
            with patch.object(benchmark, 'write_all') as write:
                self.assertTrue(fixture.handle_marker_input(b'c'))
            output = b''.join(call.args[0] for call in write.call_args_list)
            self.assertIn(b'\x1b[H\x1b[38;2;180;180;180mc', output)
            self.assertIn(b'48;2;180;180;180', output)
            self.assertTrue(fixture.capture_marker)
            self.assertEqual(fixture.color, 0)
            self.assertEqual(fixture.marker_inputs, 0)
            self.assertEqual(fixture.last_input, b'c'.hex())

            with patch.object(benchmark, 'write_all') as write:
                self.assertTrue(fixture.handle_marker_input(b'x'))
            self.assertIn(b'48;2;20;220;200', b''.join(call.args[0] for call in write.call_args_list))
            self.assertEqual(fixture.marker_inputs, 1)
            self.assertFalse(fixture.capture_marker)

    def test_refresh_restores_the_marker_without_advancing_the_sequence(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {}, clear=True):
            fixture = benchmark.Fixture(Path(directory))
            fixture.primary = True
            fixture.size = os.terminal_size((101, 46))
            with patch.object(benchmark, 'write_all') as write:
                fixture.handle_marker_input(b'c')
                write.reset_mock()
                self.assertTrue(fixture.handle_marker_input(b'r'))

            self.assertIn(b'48;2;230;20;60', b''.join(call.args[0] for call in write.call_args_list))
            self.assertFalse(fixture.capture_marker)
            self.assertEqual(fixture.marker_inputs, 0)
            self.assertEqual(fixture.color, 0)

    def test_background_fixtures_do_not_draw_a_capture_witness(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {}, clear=True):
            fixture = benchmark.Fixture(Path(directory))
            fixture.primary = False
            with patch.object(benchmark, 'write_all') as write:
                self.assertFalse(fixture.handle_marker_input(b'c'))
            write.assert_not_called()

    def test_signal_between_receipt_snapshot_and_write_keeps_new_geometry(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {}, clear=True):
            fixture = benchmark.Fixture(Path(directory))
            fixture.size = os.terminal_size((101, 46))
            fixture.phase = 'ready'
            current = os.terminal_size((145, 46))
            original_write = benchmark.atomic_json
            injected = False

            def interrupt_receipt(path, value):
                nonlocal injected
                if path == fixture.receipt and not injected:
                    injected = True
                    os.kill(os.getpid(), signal.SIGWINCH)
                original_write(path, value)

            previous_handler = signal.signal(signal.SIGWINCH, fixture.refresh_size)
            previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, set())
            try:
                with patch.object(benchmark, 'atomic_json', interrupt_receipt), patch.object(os, 'get_terminal_size', return_value=current), patch.object(benchmark, 'write_all'):
                    fixture.record()
            finally:
                signal.signal(signal.SIGWINCH, previous_handler)

            self.assertTrue(injected)
            self.assertEqual(fixture.size, current)
            receipt = json.loads(fixture.receipt.read_text())
            self.assertEqual((receipt['cols'], receipt['rows']), current)
            self.assertEqual(signal.pthread_sigmask(signal.SIG_BLOCK, set()), previous_mask)

    def test_signal_during_size_read_cannot_restore_an_older_size(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {}, clear=True):
            fixture = benchmark.Fixture(Path(directory))
            current = os.terminal_size((145, 46))
            previous = os.terminal_size((101, 46))
            calls = 0

            def interrupted_size_read(descriptor):
                nonlocal calls
                self.assertEqual(descriptor, 0)
                calls += 1
                if calls == 1:
                    os.kill(os.getpid(), signal.SIGWINCH)
                    return previous
                return current

            previous_handler = signal.signal(signal.SIGWINCH, fixture.refresh_size)
            previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, set())
            try:
                with patch.object(os, 'get_terminal_size', interrupted_size_read):
                    fixture.refresh_size()
            finally:
                signal.signal(signal.SIGWINCH, previous_handler)

            self.assertEqual(calls, 2)
            self.assertEqual(fixture.size, current)
            self.assertEqual(json.loads((Path(directory) / 'size.json').read_text()), list(current))
            receipt = json.loads(fixture.receipt.read_text())
            self.assertEqual((receipt['cols'], receipt['rows']), current)
            self.assertEqual(signal.pthread_sigmask(signal.SIG_BLOCK, set()), previous_mask)


if __name__ == '__main__':
    unittest.main()
