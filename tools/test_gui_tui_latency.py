import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from gui_tui_latency import WARMUP, aggregate_runs, client_command, runtime_program, validate_telar_grids
from terminal_bench_report import latency_samples, load_runs, markdown_report, summarize_runs, validate_telar_display_sync


def presented_run(mode, values):
    return dict(case='single', mode=mode, round=0, warmup=1, endpoint='presented',
                gpu_ms=[1000] * len(values), presentation_ms=values, input_method='key',
                presentation_drawable_ids=list(range(len(values))), presentation_clock='MTLDrawable.presentedTime',
                display_sync=dict(observed=True, enabled=True, disabled=False),
                setup_complete=True, geometry_epoch=3, viewport=[1600, 1000], marker=[235, 191],
                initial_presentation=dict(clock='MTLDrawable.presentedTime', drawable_id=0, geometry_epoch=3,
                                          viewport=[1600, 1000], marker=[235, 191], geometry_requested_at=10,
                                          gpu_completed_at=11, presented_at=12, setup_completed_at=13, first_input_at=14))


class GuiComparisonTest(unittest.TestCase):
    def test_tui_report_requires_its_final_screen_oracle(self):
        run = presented_run('gui-cpp', [1000, 4])
        run.update(case='tui', foreground_workload='ascii-tui-v1',
                   tui_validation=dict(passed=True, workload='ascii-tui-v1', sequence=2))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'comparison.json'
            path.write_text(json.dumps(dict(runs=[run])))
            self.assertEqual(len(load_runs([path])[0]), 1)
            for field, value in [('tui_validation', None), ('foreground_workload', 'marker'),
                                 ('tui_validation', dict(passed=False, workload='ascii-tui-v1', sequence=2)),
                                 ('tui_validation', dict(passed=True, workload='ascii-tui-v1', sequence=1))]:
                wrong = copy.deepcopy(run)
                wrong[field] = value
                path.write_text(json.dumps(dict(runs=[wrong])))
                with self.subTest(field=field, value=value), self.assertRaisesRegex(ValueError, 'qualified final screen'):
                    load_runs([path])

    def test_cpp_gui_cannot_silently_measure_the_reference_runtime(self):
        reference, candidate = Path('/reference/telar'), Path('/candidate/telar')
        self.assertEqual(runtime_program('gui', reference, candidate), reference)
        self.assertEqual(runtime_program('gui-cpp', reference, candidate), candidate)
        with self.assertRaisesRegex(ValueError, 'explicit runtime'):
            runtime_program('gui-cpp', reference, None)

    def test_clients_share_the_exact_fixture_arguments(self):
        fixture = ['/usr/bin/python3', '/tmp/a path/workload.py', 'literal $(argument)']
        config = Path('/tmp/a path/config.lua')
        zig = client_command('gui', Path('/tmp/telar'), None, config, fixture)
        cpp = client_command('gui-cpp', Path('/tmp/telar'), Path('/tmp/telar-gui'), config, fixture)
        self.assertEqual(zig, ['/tmp/telar', 'gui', '--config', str(config)] + fixture)
        self.assertEqual(cpp, ['/tmp/telar-gui', '--fresh', '--config', str(config)] + fixture)
        self.assertEqual(client_command('ghostty', None, None, config, fixture), fixture)

    def test_unknown_clients_cannot_launch_a_fixture(self):
        with self.assertRaises(ValueError):
            client_command('unknown', None, None, None, [])

    def test_display_sync_requires_an_observed_enabled_layer(self):
        validate_telar_display_sync(dict(display_sync=dict(observed=True, enabled=True, disabled=False)))
        for synchronization in [None, dict(observed=False, enabled=True, disabled=False),
                                dict(observed=True, enabled=False, disabled=True),
                                dict(observed=True, enabled=True, disabled=True),
                                dict(observed=1, enabled=1, disabled=0)]:
            with self.subTest(synchronization=synchronization), self.assertRaisesRegex(ValueError, 'display synchronization'):
                validate_telar_display_sync(dict(display_sync=synchronization))

    def test_grid_validation_checks_each_pane_and_display_scale(self):
        reference = dict(viewport=[1600, 1000], backing_scale=1, pty_cells=[171, 46], marker=[235, 191],
                         fixtures=[dict(role='primary', cols=85, rows=46),
                                   dict(role='background', cols=86, rows=46)])
        candidate = copy.deepcopy(reference)
        candidate['fixtures'].reverse()
        validate_telar_grids(reference, candidate)

        for field, value in [('viewport', [1601, 1000]), ('backing_scale', 2), ('pty_cells', [170, 46]), ('marker', [235, 223])]:
            candidate = copy.deepcopy(reference)
            candidate[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_telar_grids(reference, candidate)

        candidate = copy.deepcopy(reference)
        candidate['fixtures'][1]['cols'] -= 1
        with self.assertRaises(ValueError):
            validate_telar_grids(reference, candidate)

    def test_cpp_report_uses_zig_as_its_paired_reference(self):
        runs = [dict(case='single', mode=mode, round=round_index, warmup=1,
                     gpu_ms=[1000, value, value], input_method='key')
                for round_index in range(2) for mode, value in [('gui', 4), ('gui-cpp', 2)]]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'comparison.json'
            path.write_text(json.dumps(dict(runs=runs)))
            loaded, sources = load_runs([path])
            report = summarize_runs(loaded, sources)

        case = report['cases']['single']
        self.assertEqual(case['reference'], 'gui')
        self.assertEqual(case['modes']['gui-cpp']['pooled']['p50_ms'], 2)
        self.assertEqual(case['paired']['gui-cpp']['quantiles']['p50']['paired_deltas_ms'], [-2, -2])
        self.assertIn('Telar GUI C++ / Qt Quick / Telar GUI Zig', markdown_report(report))

    def test_ghostty_remains_the_reference_when_present(self):
        runs = [dict(raw=dict(input_method='key'), source='fixture', values=[value],
                     summary=dict(p50_ms=value, p95_ms=value), case='single', mode=mode, round=0)
                for mode, value in [('ghostty', 1), ('gui', 4), ('gui-cpp', 2)]]
        case = summarize_runs(runs, [])['cases']['single']
        self.assertEqual(case['reference'], 'ghostty')
        self.assertEqual(case['paired']['gui-cpp']['quantiles']['p50']['paired_deltas_ms'], [1])
        self.assertEqual(case['paired']['gui']['quantiles']['p50']['paired_deltas_ms'], [3])

    def test_a_valid_pixel_response_cannot_hide_an_invalid_background_rate(self):
        for control in [None, dict(rate_met=False)]:
            row = dict(case='splits-load', mode='gui', round=0, warmup=1,
                       gpu_ms=[1000, 4], input_method='key', failed=0,
                       background_mib_per_second=0.125)
            if control is not None:
                row['background_load'] = control
            with self.subTest(control=control), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'comparison.json'
                path.write_text(json.dumps(dict(runs=[row])))
                with self.assertRaisesRegex(ValueError, 'background workload'):
                    load_runs([path])

    def test_presentation_report_uses_presentation_samples(self):
        runs = [presented_run(mode, [1000, value])
                for mode, value in [('gui', 4), ('gui-cpp', 2)]]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'comparison.json'
            path.write_text(json.dumps(dict(runs=runs)))
            loaded, sources = load_runs([path])
            report = summarize_runs(loaded, sources)

        self.assertEqual(report['cases']['single']['modes']['gui-cpp']['pooled']['p50_ms'], 2)
        self.assertEqual(report['endpoint'], 'native_input_to_verified_drawable_presentation')
        self.assertIn('MTLDrawable.presentedTime', markdown_report(report))

    def test_cli_aggregate_keeps_the_selected_presentation_endpoint(self):
        run = presented_run('gui-cpp', [1000] * WARMUP + [2, 4])
        aggregate = aggregate_runs([run], ['single'], ['gui-cpp'])
        self.assertEqual(aggregate['single/gui-cpp']['p50_ms'], 3)

    def test_cli_aggregate_uses_run_quantiles_instead_of_pooled_samples(self):
        runs = [presented_run('gui-cpp', [1000] * WARMUP + values)
                for values in ([1, 2, 3], [4, 5, 100])]
        aggregate = aggregate_runs(runs, ['single'], ['gui-cpp'])['single/gui-cpp']
        self.assertEqual(aggregate['runs'], 2)
        self.assertEqual(aggregate['p50_ms'], 3.5)
        self.assertEqual(aggregate['max_ms'], 51.5)

    def test_gpu_and_presentation_endpoints_cannot_be_paired(self):
        runs = [dict(case='single', mode='gui', round=0, warmup=0, gpu_ms=[4]),
                presented_run('gui-cpp', [1000, 2])]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'comparison.json'
            path.write_text(json.dumps(dict(runs=runs)))
            loaded, sources = load_runs([path])
            with self.assertRaisesRegex(ValueError, 'mixed frame endpoints'):
                summarize_runs(loaded, sources)

    def test_presentation_requires_its_own_valid_samples(self):
        for samples in [None, [], [-1], [float('nan')]]:
            row = presented_run('gui', [1000, 4])
            del row['presentation_ms']
            if samples is not None:
                row['presentation_ms'] = samples
            with self.subTest(samples=samples), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'comparison.json'
                path.write_text(json.dumps(dict(runs=[row])))
                with self.assertRaisesRegex(ValueError, 'presentation|presented'):
                    load_runs([path])

    def test_presentation_requires_a_presented_marker_before_the_first_input(self):
        run = presented_run('gui', [1000, 4])
        run.pop('initial_presentation', None)

        with self.assertRaisesRegex(ValueError, 'initial presentation'):
            latency_samples(run)

    def test_initial_presentation_rejects_stale_or_incomplete_native_evidence(self):
        changes = [('clock', 'GPU completion'), ('drawable_id', None), ('drawable_id', -1),
                   ('drawable_id', True), ('geometry_epoch', 2), ('geometry_epoch', True),
                   ('viewport', [1601, 1000]), ('marker', [236, 191]),
                   ('geometry_requested_at', 12), ('gpu_completed_at', 0), ('gpu_completed_at', float('nan')),
                   ('presented_at', 0), ('presented_at', None), ('presented_at', float('inf')),
                   ('presented_at', True), ('presented_at', 9), ('setup_completed_at', 11),
                   ('first_input_at', 12), ('first_input_at', 13)]
        for field, value in changes:
            run = presented_run('gui', [1000, 4])
            run['initial_presentation'][field] = value

            with self.subTest(field=field, value=value), self.assertRaisesRegex(ValueError, 'initial presentation'):
                latency_samples(run)

        for field, value in [('geometry_epoch', True), ('setup_complete', False)]:
            run = presented_run('gui', [1000, 4])
            run[field] = value

            with self.subTest(field=field, value=value), self.assertRaisesRegex(ValueError, 'initial presentation'):
                latency_samples(run)

        for viewport, marker in [(None, None), ([], []), ([0, 1000], [0, 0]),
                                 ([1600, 1000], [1600, 191]), ([True, 1000], [0, 0])]:
            run = presented_run('gui', [1000, 4])
            run.update(viewport=viewport, marker=marker)
            run['initial_presentation'].update(viewport=viewport, marker=marker)

            with self.subTest(viewport=viewport, marker=marker), self.assertRaisesRegex(ValueError, 'initial presentation'):
                latency_samples(run)

    def test_initial_presentation_accepts_both_native_callback_orders(self):
        for gpu, presented in [(11, 12), (12, 11)]:
            run = presented_run('gui', [1000, 4])
            run['initial_presentation'].update(gpu_completed_at=gpu, presented_at=presented)

            with self.subTest(gpu=gpu, presented=presented):
                self.assertEqual(latency_samples(run), [1000, 4])

    def test_presentation_requires_native_clock_and_complete_drawable_ids(self):
        run = presented_run('gui', [1000, 4])
        self.assertEqual(latency_samples(run), [1000, 4])

        changes = [('presentation_clock', None), ('presentation_clock', 'GPU completion'),
                   ('presentation_drawable_ids', None), ('presentation_drawable_ids', []),
                   ('presentation_drawable_ids', [0]), ('presentation_drawable_ids', [0, -1]),
                   ('presentation_drawable_ids', [0, True]), ('presentation_drawable_ids', [0, 1.5])]
        for field, value in changes:
            invalid = dict(run, **{field: value})
            with self.subTest(field=field, value=value), self.assertRaisesRegex(ValueError, 'drawable identities'):
                latency_samples(invalid)

    def test_presentation_reports_require_a_telar_mode_and_verified_display_sync(self):
        run = presented_run('gui', [1000, 4])
        changes = [('mode', 'ghostty', 'Telar mode'), ('display_sync', None, 'display synchronization'),
                   ('display_sync', dict(observed=True, enabled=False, disabled=True), 'display synchronization')]
        for field, value, message in changes:
            with self.subTest(field=field, value=value), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'comparison.json'
                path.write_text(json.dumps(dict(runs=[dict(run, **{field: value})])))
                with self.assertRaisesRegex(ValueError, message):
                    load_runs([path])

    def test_cli_rejects_unavailable_frame_policies_before_launch(self):
        scenarios = [(['--mode', 'gui', '--vsync', 'false'], 'Telar comparisons require --vsync true'),
                     (['--mode', 'ghostty', '--endpoint', 'presented'], 'requires Telar-only modes')]
        for arguments, message in scenarios:
            with self.subTest(arguments=arguments), tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / 'measurements'
                command = [sys.executable, str(Path(__file__).with_name('gui_tui_latency.py')), '/unused/telar', str(output), *arguments]
                result = subprocess.run(command, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 2)
                self.assertIn(message, result.stderr)
                self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
