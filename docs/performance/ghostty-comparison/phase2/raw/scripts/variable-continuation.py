#!/usr/bin/env python3
"""Run paired Telar measurements using an already-built native probe.

Example:
  python3 /tmp/tgb-phase2-native-ab.py --baseline /tmp/old/bin/telar \
    --candidate /tmp/new/bin/telar --setup-dir /tmp/native-setup \
    --output /tmp/native-ab --tools tools --rounds 4 --samples 100 \
    --text-pattern variable --background-mib-per-second 1

The setup directory must come from gui_tui_latency.py with a fixed viewport.
No compilation, signing, or application-bundle modification occurs here.
"""
import argparse
import difflib
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import sys
import time
from types import SimpleNamespace


CASES = ('single', 'splits-load', 'tabs-load')
VERSIONS = ('baseline', 'candidate')
FOCUS_FIELDS = ('app_active_start', 'app_active_end', 'window_key_start', 'window_key_end')
HARNESS_FILES = ('gui_tui_latency.py', 'gui_tui_latency.m', 'gui_view.h',
                 'terminal_bench_fixture.py', 'gui_tui_marker.py',
                 'echo_latency.py', 'perf_e2e.py', 'graphics_roundtrip.py',
                 'load_latency.py', 'terminal_bench_report.py')


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def write_json(path, value):
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, indent=2, allow_nan=False) + '\n')
    temporary.replace(path)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def geometry(result):
    return dict(viewport=result['viewport'], scene_pixels=result['scene_pixels'],
                primary_view_pixels=result['primary_view_pixels'],
                pty_cells=result['pty_cells'], backing_scale=result['backing_scale'],
                display_max_fps=result['display_max_fps'],
                fixtures=sorted((f['role'], f['cols'], f['rows']) for f in result['fixtures']))


def validate(result, directory, options, warmup):
    expected_samples = options.samples + warmup
    expected_panes = 1 if options.case == 'single' else options.panes
    require(result['failed'] == 0 and result['setup_complete'], 'probe did not complete setup')
    require(len(result['gpu_ms']) == expected_samples, 'incorrect sample count')
    require(all(isinstance(value, (int, float)) and math.isfinite(value) and value >= 0
                for value in result['gpu_ms']), 'invalid latency sample')
    require(result.get('foreground_required') is True, 'probe does not enforce foreground')
    for field in FOCUS_FIELDS:
        flags = result.get(field, [])
        require(len(flags) == expected_samples and all(value is True for value in flags),
                f'inactive foreground observation: {field}')
    require(result['input_method'] == 'key', 'input endpoint changed')
    require(result['panes_created'] == expected_panes, 'incorrect pane count')
    require(result['requested_viewport'] == options.viewport, 'requested viewport changed')
    require(result['scene_pixels'] == options.viewport, 'scene viewport changed')
    if result['mode'] != 'ghostty' or options.case != 'splits-load':
        require(result['viewport'] == options.viewport, 'primary render target changed')
    require(len(result['fixtures']) == expected_panes, 'incorrect fixture count')
    for fixture in result['fixtures']:
        require(fixture['background'] == ('idle' if options.case == 'single' else 'flood'),
                'background workload changed')
        require(fixture.get('text_pattern') == options.text_pattern, 'text pattern changed')
    requested_rate = options.background_mib_per_second if options.case.endswith('-load') else None
    require(result.get('background_mib_per_second') == requested_rate, 'background rate changed')
    if requested_rate is not None:
        load = result.get('background_load', {})
        require(isinstance(load.get('rate_met'), bool), 'missing background rate outcome')
        require(len(load.get('fixtures', [])) == expected_panes - 1, 'missing background rate observations')
        for fixture in result['fixtures']:
            if fixture['role'] == 'background':
                require(len(fixture.get('background_progress', [])) >= 2,
                        'background rate needs two complete periodic checkpoints')
    if options.throughput:
        measured = result['throughput']
        require(measured['endpoint'] == 'pty_write_to_dsr_response', 'throughput endpoint changed')
        require(measured.get('text_pattern') == options.text_pattern, 'throughput pattern changed')
        for case in measured['cases']:
            require([case['cols'], case['rows']] == result['pty_cells'],
                    'throughput and latency PTY geometry differ')
            require(math.isfinite(case['mib_per_second']) and case['mib_per_second'] > 0,
                    'invalid throughput rate')
    if result['mode'] == 'ghostty':
        require(not (directory / 'shutdown.json').exists(), 'standalone Ghostty unexpectedly used a runtime')
        return
    shutdown = json.loads((directory / 'shutdown.json').read_text())
    require(all(shutdown.get(key) is True for key in (
        'exited', 'children_exited', 'socket_removed', 'cleanup_complete')),
        f'incomplete runtime shutdown: {shutdown}')
    require(shutdown.get('returncode') == 0, f'runtime stop failed: {shutdown}')



def schedule(manifest):
    result = []
    for round_index in range(manifest['rounds']):
        order = list(VERSIONS if round_index % 2 == 0 else VERSIONS[::-1])
        if manifest['ghostty_control']:
            order = ['ghostty'] + order if round_index % 2 == 0 else order + ['ghostty']
        for case in manifest['cases']:
            for version in order:
                result.append(dict(round=round_index, case=case, version=version))
    return result


def rate_miss_message(directory):
    return f'background output missed its requested rate; raw observations retained in {directory / "result.json"}'


def main():
    parser = argparse.ArgumentParser(description='Continue archived phase-2 runs without discarding measured rate misses.')
    parser.add_argument('--output', type=Path, default=Path('/tmp/tgb-p2-variable'))
    parser.add_argument('--check-only', action='store_true', help='validate archived observations and print the remaining schedule without writing or launching')
    args = parser.parse_args()
    output = args.output.resolve()
    manifest = json.loads((output / 'manifest.json').read_text())
    require(not (output / 'complete.json').exists(), 'series already complete')
    require(sha256(output / 'runner.py') == manifest['runner_sha256'], 'original runner changed')
    for name, expected in manifest['harness_sha256'].items():
        require(sha256(output / 'harness' / name) == expected, f'frozen harness changed: {name}')
    artifacts = dict(manifest['binaries'], **manifest['artifacts'])
    for name, artifact in artifacts.items():
        require(sha256(Path(artifact['path'])) == artifact['sha256'], f'artifact changed: {name}')
    sys.path.insert(0, str(output / 'harness'))
    from gui_tui_latency import ProbeFailure, WARMUP, background_load, measure, summarize
    from terminal_bench_report import paired_statistics
    require(WARMUP == manifest['warmup'], 'warmup changed')
    shared = {name: Path(value['path']) for name, value in manifest['artifacts'].items()}
    binaries = {name: Path(value['path']) for name, value in manifest['binaries'].items()}
    setup_dir = shared['library'].parent
    options = SimpleNamespace(samples=manifest['samples'], input_method='key', viewport=manifest['viewport'],
                              vsync=manifest['setup_manifest']['vsync'], panes=manifest['panes'], throughput=False,
                              text_pattern=manifest['text_pattern'], background_mib_per_second=manifest['background_mib_per_second'],
                              float_windows='--float-windows' in manifest['setup_manifest']['command_line'])
    require(not options.float_windows or shutil.which('aerospace'), 'aerospace CLI is unavailable')
    runs = json.loads((output / 'runs.json').read_text())
    rejected = json.loads((output / 'rejected.json').read_text()) if (output / 'rejected.json').exists() else []
    plan = schedule(manifest)
    expected_geometry, expected_payload = {}, None
    rate_misses = []

    def verify(row, context):
        nonlocal expected_payload
        options.case, options.throughput = context['case'], context['case'] == 'single'
        mode = 'ghostty' if context['version'] == 'ghostty' else manifest['mode']
        require(row['mode'] == mode and row['case'] == context['case'], 'run identity changed')
        validate(row, output / context['directory'], options, WARMUP)
        require(summarize(row['gpu_ms'][WARMUP:]) == row['summary'], 'latency summary disagrees with raw samples')
        require(sum(f['role'] == 'primary' for f in row['fixtures']) == 1, 'primary fixture count changed')
        for fixture in row['fixtures']:
            require(fixture['error'] is None and fixture['phase'] in ('ready', 'finished')
                    and min(fixture['cols'], fixture['rows']) > 0, 'invalid fixture receipt')
        if options.case.endswith('-load'):
            recomputed = background_load(row['fixtures'], options.background_mib_per_second)
            require(recomputed == row['background_load'], 'background rate evidence changed')
            if not recomputed['rate_met']:
                rate_misses.append(dict(**context, background_load=recomputed))
        key = mode, context['case']
        current = geometry(row)
        if key in expected_geometry:
            require(current == expected_geometry[key], f'geometry changed for {key}')
        else:
            expected_geometry[key] = current
        if options.throughput:
            require([entry['name'] for entry in row['throughput']['cases']] == ['ascii', 'ansi'], 'throughput workload changed')
            digests = {entry['name']: entry['payload_sha256'] for entry in row['throughput']['cases']}
            require(all(entry['bytes'] == 8 * 1024 * 1024 and entry['text_pattern'] == options.text_pattern
                        for entry in row['throughput']['cases']), 'throughput payload changed')
            if expected_payload is None:
                expected_payload = digests
            else:
                require(digests == expected_payload, 'payload bytes differ across runs')

    for row, spec in zip(runs, plan):
        require(all(row[key] == value for key, value in spec.items()), 'existing runs are not the planned prefix')
        directory = output / row['directory']
        raw = json.loads((directory / 'result.json').read_text())
        require(all(row.get(key) == value for key, value in raw.items()), 'existing aggregate changed raw observations')
        verify(row, {**spec, 'attempt': row['attempt'], 'directory': row['directory']})
    require(0 < len(runs) < len(plan), 'invalid completed prefix length')
    failure = json.loads((output / 'failure.json').read_text())
    pending = plan[len(runs)]
    require(all(failure[key] == value for key, value in pending.items()), 'failure is not the next scheduled run')
    recovered_dir = output / failure['directory']
    require(failure['error_type'] == 'RuntimeError' and failure['error'] == rate_miss_message(recovered_dir),
            'only the exact archived rate-miss failure can be recovered')
    recovered = json.loads((recovered_dir / 'result.json').read_text())
    require(recovered.get('background_load', {}).get('rate_met') is False, 'recovered run is not a measured rate miss')
    recovered_context = {**pending, 'attempt': failure['attempt'], 'directory': failure['directory']}
    verify(recovered, recovered_context)
    recovered = dict(recovered, **recovered_context,
                     binary_sha256=manifest['binaries'][pending['version']]['sha256'], rate_miss_retained=True)
    if args.check_only:
        print(json.dumps(dict(existing_runs=len(runs), recovered_run=recovered_context,
                              remaining_runs=plan[len(runs) + 1:], rate_misses=len(rate_misses)), indent=2))
        return

    continuation = output / 'continuation'
    continuation.mkdir(mode=0o700)
    for name in ('manifest.json', 'runner.py', 'runs.json', 'failure.json'):
        shutil.copy2(output / name, continuation / ('original-' + name))
    shutil.copy2(recovered_dir / 'result.json', continuation / 'recovered-result.json')
    shutil.copy2(Path(__file__).resolve(), continuation / 'runner.py')
    diff = ''.join(difflib.unified_diff((output / 'runner.py').read_text().splitlines(True),
                  Path(__file__).read_text().splitlines(True), fromfile='original-runner.py', tofile='continuation-runner.py'))
    (continuation / 'runner.diff').write_text(diff)
    continuation_manifest = dict(started_at=time.strftime('%Y-%m-%dT%H:%M:%S%z'), command_line=sys.argv,
        original_manifest_sha256=sha256(output / 'manifest.json'), original_runner_sha256=sha256(output / 'runner.py'),
        original_runs_sha256=sha256(continuation / 'original-runs.json'), recovered_result_sha256=sha256(continuation / 'recovered-result.json'),
        runner_sha256=sha256(continuation / 'runner.py'), runner_diff_sha256=sha256(continuation / 'runner.diff'),
        harness_sha256=manifest['harness_sha256'], original_completed_runs=len(runs), recovered_context=recovered_context,
        policy='Retain every complete measured rate miss without retry. Preserve the original 5% tolerance and all raw latencies. Other failures abort.',
        load_note='Requested rate is per producer. Observed rate misses remain in paired and pooled latency summaries; identical load is not claimed for those windows.')
    write_json(continuation / 'manifest.json', continuation_manifest)
    runs.append(recovered)
    write_json(recovered_dir / 'result.continued.json', recovered)
    write_json(output / 'runs.json', runs)
    write_json(continuation / 'rate-misses.json', rate_misses)
    context = recovered_context
    try:
        for spec in plan[len(runs):]:
            options.case, options.throughput = spec['case'], spec['case'] == 'single'
            mode = 'ghostty' if spec['version'] == 'ghostty' else manifest['mode']
            binary = binaries['candidate'] if spec['version'] == 'ghostty' else binaries[spec['version']]
            setup = (binary, setup_dir / 'GhosttyProbe.app', shared['library'], shared['config'], options)
            retained = False
            for attempt in range(3):
                name = f'{spec["round"]}-{spec["case"]}-{spec["version"]}' + (f'-retry{attempt}' if attempt else '')
                directory = output / name
                require(not directory.exists(), f'unexpected existing run directory: {directory}')
                context = dict(**spec, attempt=attempt, directory=name)
                try:
                    row = measure(mode, directory, setup)
                    break
                except ProbeFailure as error:
                    failed = error.result
                    if failed['failed'] != 10 or failed.get('panes_created') != 0 or failed['gpu_ms']:
                        raise
                    rejected.append(dict(**context, reason='no test window, no timing samples', result=failed))
                    write_json(continuation / 'rejected.json', rejected)
                    if attempt == 2:
                        raise
                except RuntimeError as error:
                    if str(error) != rate_miss_message(directory):
                        raise
                    row = json.loads((directory / 'result.json').read_text())
                    require(row.get('background_load', {}).get('rate_met') is False, 'rate-miss exception lacks matching evidence')
                    retained = True
                    break
            verify(row, context)
            binary_hash = manifest['artifacts']['ghostty']['sha256'] if spec['version'] == 'ghostty' else manifest['binaries'][spec['version']]['sha256']
            row = dict(row, **context, binary_sha256=binary_hash, rate_miss_retained=retained)
            write_json(directory / 'result.continued.json', row)
            runs.append(row)
            write_json(output / 'runs.json', runs)
            write_json(continuation / 'rate-misses.json', rate_misses)
            print(json.dumps(dict(**context, rate_miss_retained=retained, **row['summary'])), flush=True)

        for name, artifact in artifacts.items():
            require(sha256(Path(artifact['path'])) == artifact['sha256'], f'artifact changed: {name}')
        for name, expected in manifest['harness_sha256'].items():
            require(sha256(output / 'harness' / name) == expected, f'frozen harness changed: {name}')
        paired, pooled, throughput = {}, {}, {}
        measured_versions = (*VERSIONS, 'ghostty') if manifest['ghostty_control'] else VERSIONS
        for case in manifest['cases']:
            before = [row for row in runs if row['version'] == 'baseline' and row['case'] == case]
            after = [row for row in runs if row['version'] == 'candidate' and row['case'] == case]
            paired[case] = paired_statistics(before, after)
            pooled[case] = {version: summarize([value for row in runs if row['case'] == case and row['version'] == version
                                               for value in row['gpu_ms'][WARMUP:]]) for version in measured_versions}
        for version in measured_versions:
            throughput[version] = {}
            for workload in ('ascii', 'ansi'):
                values = [entry['mib_per_second'] for row in runs if row['version'] == version and row['case'] == 'single'
                          for entry in row['throughput']['cases'] if entry['name'] == workload]
                if values:
                    target = manifest['throughput_target_mib_per_second']
                    throughput[version][workload] = dict(rounds=values, median=statistics.median(values), minimum=min(values), maximum=max(values),
                                                        target_mib_per_second=target, all_rounds_meet_target=all(value >= target for value in values))
        write_json(output / 'paired.json', dict(latency=paired, throughput=throughput,
                   note='Candidate minus baseline; bootstrap units are complete paired rounds. All measured rate misses are retained.',
                   load_note=continuation_manifest['load_note'], rate_misses=rate_misses))
        write_json(output / 'summary.json', dict(pooled_latency_ms=pooled, throughput_mib_per_second=throughput,
                   requested_background_mib_per_second=manifest['background_mib_per_second'],
                   background_load_runs=[dict(round=row['round'], case=row['case'], version=row['version'],
                                         background_load=row['background_load']) for row in runs if 'background_load' in row],
                   rate_misses=rate_misses, load_note=continuation_manifest['load_note']))
        for version in measured_versions:
            write_json(output / f'{version}.json', dict(manifest=dict(manifest, version=version), continuation=continuation_manifest,
                       runs=[row for row in runs if row['version'] == version]))
        write_json(output / 'complete.json', dict(runs=len(runs), rejected_startups=len(rejected), retained_rate_misses=len(rate_misses)))
    except BaseException as error:
        write_json(continuation / 'failure.json', dict(**context, error_type=type(error).__name__, error=str(error)))
        raise


if __name__ == '__main__':
    main()
