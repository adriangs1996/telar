import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from benchmark_host import HostLoadGate, HostLoadRejected, host_snapshot
import gui_tui_latency


def observation(load=(1, 2, 3), compilers=None):
    return dict(uptime='host uptime', load=list(load), active_compilers=compilers or [], processes='fixture')


class HostLoadGateTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / 'host.json'

    def report(self):
        return json.loads(self.path.read_text())

    def test_high_initial_load_prevents_any_work(self):
        gate = HostLoadGate(self.path, [5, 7.5])
        with patch('benchmark_host.host_snapshot', return_value=observation((6, 2, 3))):
            with self.assertRaises(HostLoadRejected):
                with gate.run('A'):
                    self.fail('Work must not start')
        self.assertEqual(self.report()['status'], 'deferred')
        self.assertEqual(self.report()['started_runs'], 0)
        self.assertFalse(self.report()['eligible'])

    def test_interference_after_second_variant_discards_entire_series(self):
        gate = HostLoadGate(self.path, [5, 7.5])
        completed = []
        snapshots = [observation(), observation(), observation(), observation((1, 8, 3))]
        with patch('benchmark_host.host_snapshot', side_effect=snapshots):
            with gate.run('A'):
                completed.append('A')
            with self.assertRaises(HostLoadRejected):
                with gate.run('B'):
                    completed.append('B')
        self.assertEqual(completed, ['A', 'B'])
        self.assertEqual(self.report()['status'], 'discarded')
        self.assertEqual(self.report()['started_runs'], 2)
        with patch('benchmark_host.host_snapshot', return_value=observation()) as sampler:
            with self.assertRaises(HostLoadRejected):
                gate.finish()
            sampler.assert_not_called()
        self.assertFalse(self.report()['eligible'])

    def test_capture_failure_is_not_a_low_load_result(self):
        gate = HostLoadGate(self.path, [5, 7.5])
        with patch('benchmark_host.host_snapshot', side_effect=subprocess.TimeoutExpired('ps', 5)):
            with self.assertRaises(HostLoadRejected):
                gate.checkpoint('before-series')
        self.assertIn('TimeoutExpired', self.report()['observations'][0]['error'])
        self.assertFalse(self.report()['eligible'])

    def test_active_compiler_rejects_even_with_low_load_average(self):
        gate = HostLoadGate(self.path, [5, 7.5])
        compiler = dict(pid=123, cpu_percent=80, command='/tools/clang++')
        with patch('benchmark_host.host_snapshot', return_value=observation(compilers=[compiler])):
            with self.assertRaises(HostLoadRejected):
                gate.checkpoint('before-series')
        self.assertEqual(self.report()['observations'][0]['active_compilers'], [compiler])

    def test_success_requires_final_check_and_cannot_be_reopened(self):
        gate = HostLoadGate(self.path, [5, 7.5])
        with patch('benchmark_host.host_snapshot', side_effect=lambda: observation()):
            with gate.run('A'):
                self.assertFalse(self.report()['eligible'])
            self.assertFalse(self.report()['eligible'])
            gate.finish()
            self.assertTrue(self.report()['eligible'])
            self.assertEqual(self.report()['observations'][-1]['phase'], 'after-series')
            with self.assertRaisesRegex(RuntimeError, 'already finished'):
                gate.checkpoint('another-series')

    def test_workload_failure_still_observes_after_cleanup(self):
        gate = HostLoadGate(self.path, [5, 7.5])
        events = []
        def sample():
            events.append('snapshot')
            return observation()
        with patch('benchmark_host.host_snapshot', side_effect=sample):
            with self.assertRaisesRegex(ValueError, 'workload failure'):
                with gate.run('A'):
                    try:
                        raise ValueError('workload failure')
                    finally:
                        events.append('cleanup')
        self.assertEqual(events, ['snapshot', 'cleanup', 'snapshot'])
        self.assertFalse(self.report()['eligible'])

    def test_limits_must_be_finite_positive_and_preserve_existing_report(self):
        for limits in ([0, 1], [-1, 1], [float('nan'), 1], [1, float('inf')], [1]):
            with self.assertRaises(ValueError):
                HostLoadGate(self.path, limits)
        self.path.write_text('existing')
        with self.assertRaises(FileExistsError):
            HostLoadGate(self.path)
        self.assertEqual(self.path.read_text(), 'existing')

    def test_empty_series_cannot_qualify(self):
        gate = HostLoadGate(self.path, [5, 7.5])
        with patch('benchmark_host.host_snapshot', return_value=observation()):
            with self.assertRaisesRegex(ValueError, 'empty'):
                gate.finish()
        self.assertFalse(self.report()['eligible'])


class HostSnapshotTest(unittest.TestCase):
    def test_process_commands_with_spaces_and_versioned_compilers(self):
        processes = 'PID %CPU COMMAND\n1 3.0 /sbin/launchd\n2 90.0 /tool chain/clang++-23\n3 70.0 /app/clangd\n4 50.0 /path/zig\n'
        with patch('benchmark_host.subprocess.check_output', side_effect=['uptime', processes]), patch('benchmark_host.os.getloadavg', return_value=(1, 2, 3)):
            sample = host_snapshot()
        self.assertEqual([row['pid'] for row in sample['active_compilers']], [2, 4])
        self.assertEqual(sample['processes'], processes)

    def test_missing_processes_and_nonfinite_load_fail_closed(self):
        for load, processes in [((1, 2, 3), ''), ((float('nan'), 2, 3), 'PID %CPU COMMAND\n1 2 /bin/test'), ((1, 2, 3), 'PID %CPU COMMAND\n1 nan /bin/test')]:
            with patch('benchmark_host.subprocess.check_output', side_effect=['uptime', processes]), patch('benchmark_host.os.getloadavg', return_value=load):
                with self.assertRaises(ValueError):
                    host_snapshot()


class NativeRunnerHostGateTest(unittest.TestCase):
    def test_high_load_stops_before_probe_build_or_workload(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / 'series'
            binary = Path(temporary) / 'reference'
            binary.write_bytes(b'fixture')
            arguments = ['gui_tui_latency.py', str(binary), str(directory), '--mode', 'gui']
            with patch('sys.argv', arguments), patch('benchmark_host.host_snapshot', return_value=observation((20, 20, 20))), patch('gui_tui_latency.subprocess.run') as command, patch('gui_tui_latency.measure') as measure:
                with self.assertRaises(HostLoadRejected):
                    gui_tui_latency.main()
            command.assert_not_called()
            measure.assert_not_called()
            self.assertEqual(json.loads((directory / 'host-load.json').read_text())['status'], 'deferred')
            self.assertFalse((directory / 'probe.dylib').exists())
            self.assertFalse((directory / 'comparison.json').exists())

    def test_late_interference_cannot_publish_partial_aggregate(self):
        def command_output(command, **options):
            if command[:3] == ['sysctl', '-n', 'hw.memsize']:
                return '1024'
            return 'fixture' if options.get('text') else b''

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / 'series'
            binary = Path(temporary) / 'reference'
            binary.write_bytes(b'fixture')
            arguments = ['gui_tui_latency.py', str(binary), str(directory), '--mode', 'gui', '--rounds', '2', '--max-load', '5', '7.5']
            snapshots = [observation() for _ in range(5)] + [observation((20, 20, 20))]
            with patch('sys.argv', arguments), patch('benchmark_host.host_snapshot', side_effect=snapshots), patch('gui_tui_latency.subprocess.check_output', side_effect=command_output), patch('gui_tui_latency.subprocess.run'), patch('gui_tui_latency.measure', side_effect=lambda *args: {'mode': 'gui', 'case': 'single'}) as measure, patch('gui_tui_latency.aggregate_runs') as aggregate:
                with self.assertRaises(HostLoadRejected):
                    gui_tui_latency.main()
            self.assertEqual(measure.call_count, 2)
            aggregate.assert_not_called()
            self.assertEqual(len(json.loads((directory / 'runs.json').read_text())), 1)
            self.assertEqual(json.loads((directory / 'host-load.json').read_text())['status'], 'discarded')
            self.assertFalse((directory / 'comparison.json').exists())
            self.assertTrue((directory / 'probe-source/benchmark_host.py').is_file())


if __name__ == '__main__':
    unittest.main()
