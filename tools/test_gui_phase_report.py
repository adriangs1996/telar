import copy
import json
from pathlib import Path
import tempfile
import unittest

from gui_phase_report import analyze_directory, gui_stages, load_trace, native_stages
from test_gui_tui_latency import presented_run


def fixture():
    result = presented_run('gui-cpp', [40, 40])
    result.update(failed=0, warmup=0, interaction='previous_tab', gpu_ms=[13, 13], gpu_work_ms=[1, 1])
    result['switch_samples'] = [dict(input_at=start, commit_at=start + .010,
                                    gpu_started_at=start + .011, gpu_ended_at=start + .012,
                                    presented_at=start + .040, completed_at=start + .013,
                                    commit_count=1, observed_tab=index)
                                for index, start in enumerate([20, 21])]
    for name in ('app_active_start', 'app_active_end', 'window_key_start', 'window_key_end'):
        result[name] = [True, True]
    records = []

    def record(name, start, end=None, work=0, kind=0):
        records.append(dict(name=name, begin_ns=round(start * 1e9), end_ns=round((end or start) * 1e9),
                            thread=1, object=1, work=work, kind=kind))

    record('trace.clock', 19, 19.000001, work=19_000_000_500)
    for index, start in enumerate([20, 21]):
        record('socket.consume', start + .001, start + .003, work=0x82)
        record('frame.dispatch', start + .002, start + .003, work=index + 10, kind=index + 100)
        record('qt.before_sync', start + .004)
        record('terminal.paint', start + .005, start + .006, work=index + 10, kind=index + 100)
        record('qt.after_sync', start + .007)
        record('qt.before_render', start + .008)
        record('qt.after_render', start + .009)
    record('trace.clock', 22, 22.000001, work=22_000_000_500)
    records.sort(key=lambda row: row['begin_ns'])
    return result, records, {0: 10, 1: 11}


class GuiPhaseReportTest(unittest.TestCase):
    def test_native_intervals_partition_each_sample(self):
        result, _, _ = fixture()
        stages = native_stages(result)['samples']
        for index, total in enumerate(stages['input_to_presentation']):
            self.assertAlmostEqual(sum(stages[name][index] for name in
                                       ('input_to_commit', 'commit_to_gpu', 'gpu_execution', 'gpu_to_presentation')), total)

    def test_typing_uses_actual_key_pane_identity(self):
        result, records, _ = fixture()
        result['submission_samples'] = result.pop('switch_samples')
        result.pop('interaction')
        for index, sample in enumerate(result['submission_samples']):
            key = dict(name='terminal.key', begin_ns=round((sample['input_at'] + .0001) * 1e9),
                       end_ns=round((sample['input_at'] + .0002) * 1e9), thread=1, object=1, work=index + 10, kind=0)
            records.append(key)
        self.assertEqual(len(native_stages(result)['samples']['input_to_commit']), 2)
        self.assertEqual([row['pane_id'] for row in gui_stages(result, records, {})['matches']], [10, 11])
        records[-1]['work'] = 0
        with self.assertRaisesRegex(ValueError, 'terminal input identity'):
            gui_stages(result, records, {})

    def test_encoder_interval_requires_one_ordered_drawable_pass(self):
        result, _, _ = fixture()
        for sample in result['switch_samples']:
            sample.update(encoder_started_at=sample['input_at'] + .005, encoder_count=1)
        analysis = native_stages(result)['encoding']
        self.assertAlmostEqual(analysis['summary']['encoder_to_commit']['mean_ms'], 5)
        for field, value in [('encoder_count', 2), ('encoder_count', True), ('encoder_started_at', 22),
                             ('encoder_started_at', None)]:
            wrong = copy.deepcopy(result)
            wrong['switch_samples'][0][field] = value
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'drawable encoder'):
                native_stages(wrong)

    def test_callback_can_follow_presentation(self):
        result, _, _ = fixture()
        result['switch_samples'][0]['completed_at'] = 20.05
        result['gpu_ms'][0] = 50
        native_stages(result)

    def test_native_negative_controls(self):
        for field, value in [('commit_count', 2), ('commit_count', True), ('commit_at', 20.05),
                             ('gpu_started_at', None), ('gpu_ended_at', float('nan')), ('completed_at', 20.01)]:
            result, _, _ = fixture()
            result['switch_samples'][0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                native_stages(result)
        for field, value in [('failed', 1), ('endpoint', 'gpu'), ('display_sync', None), ('initial_presentation', None),
                             ('window_key_start', [True, False]), ('app_active_end', [True])]:
            result, _, _ = fixture()
            result[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                native_stages(result)

    def test_gui_stages_match_the_exact_pane_and_frame(self):
        result, records, panes = fixture()
        analysis = gui_stages(result, records, panes)
        self.assertEqual([row['frame_id'] for row in analysis['matches']], [100, 101])
        for index in range(2):
            self.assertAlmostEqual(sum(values[index] for values in analysis['samples'].values()), 10)
        result['warmup'] = 1
        self.assertTrue(all(len(values) == 1 for values in gui_stages(result, records, panes)['samples'].values()))

    def test_graphics_notifications_cannot_impersonate_a_frame_payload(self):
        result, records, panes = fixture()
        duplicate = copy.deepcopy(next(row for row in records if row['name'] == 'frame.dispatch'))
        duplicate.update(begin_ns=20_003_200_000, end_ns=20_003_300_000)
        graphics = copy.deepcopy(next(row for row in records if row['name'] == 'socket.consume'))
        graphics.update(begin_ns=20_003_100_000, end_ns=20_003_400_000, work=0x8d)
        records.extend([graphics, duplicate])
        gui_stages(result, records, panes)
        graphics['work'] = 0x82
        with self.assertRaisesRegex(ValueError, 'ambiguous exact-frame'):
            gui_stages(result, records, panes)

    def test_gui_negative_controls(self):
        for target, change in [('terminal.paint', dict(work=99)), ('frame.dispatch', dict(kind=99)),
                               ('qt.after_sync', dict(begin_ns=20_011_000_000, end_ns=20_011_000_000)),
                               ('trace.clock', dict(end_ns=20_500_000_000))]:
            result, records, panes = fixture()
            next(row for row in records if row['name'] == target).update(change)
            with self.subTest(target=target), self.assertRaises(ValueError):
                gui_stages(result, records, panes)
        result, records, panes = fixture()
        records.append(copy.deepcopy(next(row for row in records if row['name'] == 'frame.dispatch')))
        with self.assertRaisesRegex(ValueError, 'ambiguous exact-frame'):
            gui_stages(result, records, panes)

    def test_report_requires_host_boundaries_and_owned_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = root / '0-cpp'
            run.mkdir()
            host = root / 'host.json'
            for status, eligible, phases in [('discarded', False, ['before:0-cpp', 'after:0-cpp']),
                                             ('qualified', True, ['before:0-other', 'after:0-other'])]:
                host.write_text(json.dumps(dict(status=status, eligible=eligible,
                                                observations=[dict(phase=phase, valid=True) for phase in phases])))
                with self.assertRaisesRegex(ValueError, 'host boundaries'):
                    analyze_directory(run, host)
            host.write_text(json.dumps(dict(status='qualified', eligible=True, observations=[
                dict(phase='before:0-cpp', valid=True), dict(phase='after:0-cpp', valid=True)])))
            (run / 'result.json').write_text('{}')
            (run / 'shutdown.json').write_text(json.dumps(dict(returncode=0, exited=False)))
            with self.assertRaisesRegex(ValueError, 'cleanup'):
                analyze_directory(run, host)

    def test_typing_initial_receipt_is_not_a_final_count_oracle(self):
        result, _, _ = fixture()
        result['submission_samples'] = result.pop('switch_samples')
        result.pop('interaction')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = root / '0-cpp'
            (run / 'receipts').mkdir(parents=True)
            host = root / 'host.json'
            host.write_text(json.dumps(dict(status='qualified', eligible=True, observations=[
                dict(phase='before:0-cpp', valid=True), dict(phase='after:0-cpp', valid=True)])))
            (run / 'result.json').write_text(json.dumps(result))
            (run / 'shutdown.json').write_text(json.dumps(dict(returncode=0, exited=True, children_exited=True,
                                                              socket_removed=True, cleanup_complete=True)))
            receipt = run / 'receipts/123.json'
            receipt.write_text(json.dumps(dict(role='primary', phase='ready', error=None, marker_inputs=0)))
            report = analyze_directory(run, host)
            self.assertFalse(report['workload']['final_fixture_receipt'])
            self.assertIsNone(report['workload']['final_fixture_inputs'])
            receipt.write_text(json.dumps(dict(role='primary', phase='finished', error=None, marker_inputs=0)))
            with self.assertRaisesRegex(ValueError, 'Final typing receipt'):
                analyze_directory(run, host)
            receipt.write_text(json.dumps(dict(role='primary', phase='finished', error=None, marker_inputs=2)))
            self.assertEqual(analyze_directory(run, host)['workload']['final_fixture_inputs'], 2)

    def test_trace_identity_overflow_and_clock_controls(self):
        _, records, _ = fixture()
        header = dict(pid=123, clock='CLOCK_UPTIME_RAW ns', count=len(records), dropped=0, capacity=100)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'trace.jsonl'

            def write(head, rows):
                path.write_text('\n'.join(json.dumps(row) for row in [head, *rows]) + '\n')

            write(header, records)
            self.assertEqual(load_trace(path, 123), records)
            for field, value in [('pid', 456), ('dropped', 1), ('count', len(records) + 1), ('clock', 'wall time')]:
                write(dict(header, **{field: value}), records)
                with self.subTest(field=field), self.assertRaises(ValueError):
                    load_trace(path, 123)
            wrong = copy.deepcopy(records)
            wrong[0]['work'] = wrong[0]['end_ns'] + 1
            write(header, wrong)
            with self.assertRaisesRegex(ValueError, 'qualified epoch'):
                load_trace(path, 123)
            write(dict(header, count=len(records) - 1), records[:-1])
            with self.assertRaisesRegex(ValueError, 'clock brackets'):
                load_trace(path, 123)


if __name__ == '__main__':
    unittest.main()
