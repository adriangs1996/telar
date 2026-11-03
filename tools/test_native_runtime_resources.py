import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import native_runtime_resources as resources


def snapshot():
    return dict(pid=42, before_ns=100, after_ns=110, timebase_numer=125,
                timebase_denom=3, start_abstime=1, exit_abstime=0, uuid='12' * 16,
                user_ticks=100, system_ticks=20, idle_wakeups=1,
                interrupt_wakeups=2, pageins=3, resident_bytes=1000,
                footprint_bytes=800, lifetime_max_footprint_bytes=900)


class ResourceTests(unittest.TestCase):
    def setUp(self):
        self.start = snapshot()
        self.end = dict(self.start, before_ns=200, after_ns=220, user_ticks=340,
                        system_ticks=68, idle_wakeups=3)

    def test_mach_timebase_and_bracketed_window(self):
        result = resources.interval(self.start, self.end)
        self.assertAlmostEqual(result['user_cpu_seconds'], .000010)
        self.assertAlmostEqual(result['system_cpu_seconds'], .000002)
        self.assertAlmostEqual(result['minimum_wall_seconds'], 90e-9)
        self.assertAlmostEqual(result['maximum_wall_seconds'], 120e-9)
        self.assertEqual(result['idle_wakeups'], 2)
        self.assertNotIn('peak_rss', result)

    def test_identity_clock_and_counter_controls(self):
        changes = dict(pid=43, start_abstime=2, uuid='34' * 16, timebase_numer=1,
                       timebase_denom=0, before_ns=109, after_ns=199,
                       exit_abstime=1, user_ticks=99, system_ticks=19,
                       idle_wakeups=0, interrupt_wakeups=1, pageins=2)
        for key, value in changes.items():
            with self.subTest(key=key), self.assertRaises(ValueError):
                resources.interval(self.start, dict(self.end, **{key: value}))

    def test_hardware_counters_are_raw_and_optional(self):
        result = resources.interval(dict(self.start, instructions=100, cycles=200),
                                    dict(self.end, instructions=350, cycles=900))
        self.assertEqual(result['instructions'], 250)
        self.assertEqual(result['cycles'], 700)
        self.assertTrue(result['hardware_counters_available'])
        self.assertAlmostEqual(result['user_cpu_seconds'], .000010)
        self.assertNotIn('instructions', resources.interval(self.start, self.end))
        unavailable = resources.interval(dict(self.start, instructions=0, cycles=0),
                                         dict(self.end, instructions=0, cycles=0))
        self.assertFalse(unavailable['hardware_counters_available'])
        idle = resources.interval(dict(self.start, instructions=100, cycles=200),
                                  dict(self.end, instructions=100, cycles=200))
        self.assertTrue(idle['hardware_counters_available'])
        self.assertEqual(idle['instructions'], 0)

    def test_hardware_counter_integrity(self):
        start = dict(self.start, instructions=100, cycles=200)
        end = dict(self.end, instructions=350, cycles=900)
        for key in ('instructions', 'cycles'):
            for value in (-1, 2**64, 1.5, True, None, start[key] - 1):
                with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                    resources.interval(start, dict(end, **{key: value}))
            missing = dict(end)
            del missing[key]
            with self.subTest(missing=key), self.assertRaises(ValueError):
                resources.interval(start, missing)
        with self.assertRaises(ValueError):
            resources.interval(self.start, end)
        with self.assertRaises(ValueError):
            resources.interval(start, self.end)

    def test_invalid_representations_and_missing_fields(self):
        for value in (True, -1, 2**64, 1.5, float('nan'), float('inf'), '100', None):
            with self.subTest(value=value), self.assertRaises(ValueError):
                resources.interval(dict(self.start, user_ticks=value), self.end)
        for key in self.start:
            missing = dict(self.start)
            del missing[key]
            with self.subTest(missing=key), self.assertRaises(ValueError):
                resources.interval(missing, self.end)
        with self.assertRaises(ValueError):
            resources.validate_snapshot([])

    @patch.object(resources.subprocess, 'check_output')
    def test_helper_must_return_requested_pid(self, output):
        output.return_value = json.dumps(self.start)
        with self.assertRaises(ValueError):
            resources.snapshot('/helper', 43)
        output.assert_called_once_with(['/helper', '43'], text=True, timeout=5)

    def harness(self):
        identity = dict(pid=42, path='/owned/runtime', sha256='sha')
        return SimpleNamespace(runtime_identity=Mock(return_value=dict(identity, socket='/owned/socket')),
                               process_identity=Mock(return_value=identity),
                               stop_runtime=Mock(return_value=dict(cleanup_complete=True)))

    @patch.object(resources, 'snapshot')
    def test_success_restores_hooks_and_preserves_cleanup(self, collect):
        collect.side_effect = [self.start, self.end]
        harness = self.harness()
        identify, stop = harness.runtime_identity, harness.stop_runtime
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'resources.json'
            with resources.capture(harness, path, '/helper') as state:
                harness.runtime_identity('/owned/socket', '/owned/runtime')
                self.assertEqual(collect.call_count, 1)
                harness.stop_runtime('/owned/runtime', {})
            self.assertTrue(state['interval']['valid'])
            self.assertTrue(json.loads(path.read_text())['cleanup']['cleanup_complete'])
        self.assertIs(harness.runtime_identity, identify)
        self.assertIs(harness.stop_runtime, stop)
        stop.assert_called_once()

    @patch.object(resources, 'snapshot')
    def test_failed_capture_still_stops_owned_runtime(self, collect):
        collect.side_effect = [self.start, OSError('resource read failed')]
        harness = self.harness()
        stop = harness.stop_runtime
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'resources.json'
            with self.assertRaises(ValueError):
                with resources.capture(harness, path, '/helper'):
                    harness.runtime_identity('/owned/socket', '/owned/runtime')
                    harness.stop_runtime('/owned/runtime', {})
            result = json.loads(path.read_text())
            self.assertTrue(result['cleanup']['cleanup_complete'])
            self.assertNotIn('interval', result)
        self.assertIs(harness.stop_runtime, stop)
        stop.assert_called_once()

    @patch.object(resources, 'snapshot')
    def test_reused_pid_is_rejected_before_second_snapshot(self, collect):
        collect.return_value = self.start
        harness = self.harness()
        harness.process_identity.return_value = dict(pid=42, path='/other/runtime', sha256='other')
        stop = harness.stop_runtime
        with tempfile.TemporaryDirectory() as directory, self.assertRaises(ValueError):
            with resources.capture(harness, Path(directory) / 'resources.json', '/helper'):
                harness.runtime_identity('/owned/socket', '/owned/runtime')
                harness.stop_runtime('/owned/runtime', {})
        self.assertEqual(collect.call_count, 1)
        stop.assert_called_once()

    @patch.object(resources, 'snapshot')
    def test_native_failure_is_not_hidden_by_resource_failure(self, collect):
        collect.side_effect = [self.start, OSError('resource read failed')]
        harness = self.harness()
        stop = harness.stop_runtime
        with tempfile.TemporaryDirectory() as directory, self.assertRaisesRegex(RuntimeError, 'native failure'):
            with resources.capture(harness, Path(directory) / 'resources.json', '/helper'):
                harness.runtime_identity('/owned/socket', '/owned/runtime')
                try:
                    raise RuntimeError('native failure')
                finally:
                    harness.stop_runtime('/owned/runtime', {})
        self.assertIs(harness.stop_runtime, stop)
        stop.assert_called_once()

    def test_existing_receipt_is_not_overwritten(self):
        harness = self.harness()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'resources.json'
            path.write_text('original')
            with self.assertRaises(FileExistsError):
                with resources.capture(harness, path, '/helper'):
                    self.fail('must not start')
            self.assertEqual(path.read_text(), 'original')


if __name__ == '__main__':
    unittest.main()
