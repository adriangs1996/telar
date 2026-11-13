import importlib.util
import os
from pathlib import Path
import signal
import unittest
from unittest.mock import patch


fixture_path = Path(__file__).resolve().parents[3] / 'tools' / 'terminal_bench_fixture.py'
spec = importlib.util.spec_from_file_location('terminal_fixture', fixture_path)
fixture_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture_module)


class TerminalFixtureResizeTest(unittest.TestCase):
    def setUp(self):
        self.fixture = object.__new__(fixture_module.Fixture)
        self.fixture.directory = Path('/unused')
        self.fixture.primary = True
        self.fixture.phase = 'starting'
        self.fixture.geometry_generation = 0
        self.fixture.size = os.terminal_size((80, 24))
        self.records = []
        self.fixture.record = lambda: self.records.append(tuple(self.fixture.size))
        self.previous_mask = signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGWINCH})
        self.previous_handler = signal.signal(signal.SIGWINCH, self.fixture.refresh_size)

    def tearDown(self):
        signal.signal(signal.SIGWINCH, self.previous_handler)
        signal.pthread_sigmask(signal.SIG_SETMASK, self.previous_mask)

    def test_resize_signal_during_size_write_keeps_both_files_current(self):
        written = []
        triggered = False

        def write_size(path, value):
            nonlocal triggered
            self.assertEqual(path.name, 'size.json')
            if not triggered:
                triggered = True
                os.kill(os.getpid(), signal.SIGWINCH)
            written.append(tuple(value))

        sizes = [os.terminal_size((66, 21)), os.terminal_size((56, 21))]
        with patch.object(fixture_module.os, 'get_terminal_size', side_effect=sizes), patch.object(fixture_module, 'atomic_json', side_effect=write_size):
            self.fixture.refresh_size()

        self.assertEqual(written, [(66, 21), (56, 21)])
        self.assertEqual(self.records, written)
        self.assertEqual(tuple(self.fixture.size), written[-1])
        self.assertEqual(self.fixture.geometry_generation, 2)
        self.assertNotIn(signal.SIGWINCH, signal.pthread_sigmask(signal.SIG_BLOCK, set()))

    def test_write_failure_restores_signal_mask(self):
        with patch.object(fixture_module.os, 'get_terminal_size', return_value=os.terminal_size((56, 21))), patch.object(fixture_module, 'atomic_json', side_effect=OSError('fixture write failure')):
            with self.assertRaisesRegex(OSError, 'fixture write failure'):
                self.fixture.refresh_size()

        self.assertNotIn(signal.SIGWINCH, signal.pthread_sigmask(signal.SIG_BLOCK, set()))

    def test_unchanged_size_keeps_generation_and_restores_mask(self):
        with patch.object(fixture_module.os, 'get_terminal_size', return_value=self.fixture.size), patch.object(fixture_module, 'atomic_json') as write_size:
            self.fixture.refresh_size()

        write_size.assert_not_called()
        self.assertEqual(self.fixture.geometry_generation, 0)
        self.assertEqual(self.records, [])
        self.assertNotIn(signal.SIGWINCH, signal.pthread_sigmask(signal.SIG_BLOCK, set()))

    def test_existing_blocked_mask_is_preserved(self):
        signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGWINCH})
        with patch.object(fixture_module.os, 'get_terminal_size', return_value=self.fixture.size):
            self.fixture.refresh_size()

        self.assertIn(signal.SIGWINCH, signal.pthread_sigmask(signal.SIG_BLOCK, set()))

    def test_background_resize_does_not_replace_primary_size_file(self):
        self.fixture.primary = False
        with patch.object(fixture_module.os, 'get_terminal_size', return_value=os.terminal_size((28, 21))), patch.object(fixture_module, 'atomic_json') as write_size:
            self.fixture.refresh_size()

        write_size.assert_not_called()
        self.assertEqual(self.records, [(28, 21)])
        self.assertEqual(self.fixture.geometry_generation, 1)


if __name__ == '__main__':
    unittest.main()
