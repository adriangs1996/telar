#!/usr/bin/env python3
"""Run paired Telar measurements using an already-built native probe.

Example:
  python3 /tmp/tgb-phase2-final-native.py --baseline /tmp/old/bin/telar \
    --candidate /tmp/new/bin/telar --setup-dir /tmp/native-setup \
    --output /tmp/native-ab --tools tools --rounds 4 --samples 100 \
    --text-pattern variable --background-mib-per-second 1 --record-rate-misses

The setup directory must come from gui_tui_latency.py with a fixed viewport.
No compilation, signing, or application-bundle modification occurs here.
"""
import argparse
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
        require(load.get('rate_met') is True or (options.record_rate_misses and load.get('rate_met') is False),
                f'background output missed its requested rate: {load}')
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', required=True, type=Path)
    parser.add_argument('--candidate', required=True, type=Path)
    parser.add_argument('--setup-dir', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path, help='new short /tmp directory')
    parser.add_argument('--tools', type=Path, default=Path.cwd() / 'tools')
    parser.add_argument('--rounds', type=int, default=4)
    parser.add_argument('--samples', type=int, default=100)
    parser.add_argument('--cases', nargs='+', choices=CASES, default=list(CASES))
    parser.add_argument('--text-pattern', choices=('repeat', 'variable'), default='repeat')
    parser.add_argument('--background-mib-per-second', type=float,
                        help='requested MiB/s per background producer/pane; omitted means unlimited')
    parser.add_argument('--mode', choices=('gui', 'tui'), default='gui')
    parser.add_argument('--ghostty-control', action='store_true',
                        help='measure standalone Ghostty once per single case and round; never in loaded layouts')
    parser.add_argument('--record-rate-misses', action='store_true',
                        help='retain complete measurements with rate_met=false; preserve the original tolerance and never retry them')
    parser.add_argument('--throughput-target-mib-per-second', type=float, default=80)
    args = parser.parse_args()
    if not 1 <= args.rounds <= 10 or not 1 <= args.samples <= 400:
        parser.error('rounds must be 1..10 and samples 1..400')
    if len(args.cases) != len(set(args.cases)):
        parser.error('cases must be unique')
    if args.ghostty_control and 'single' not in args.cases:
        parser.error('--ghostty-control requires the single case')
    if args.background_mib_per_second is not None:
        if not math.isfinite(args.background_mib_per_second) or not 1 / 1024 <= args.background_mib_per_second <= 1024:
            parser.error('background MiB/s must be finite and within [0.0009765625, 1024]')
        if not any(case.endswith('-load') for case in args.cases):
            parser.error('background rate requires a load case')
    if not math.isfinite(args.throughput_target_mib_per_second) or args.throughput_target_mib_per_second <= 0:
        parser.error('throughput target must be positive and finite')

    output, setup_dir, tools_dir = args.output.resolve(), args.setup_dir.resolve(), args.tools.resolve()
    require(not output.exists(), f'output already exists: {output}')
    require(len(os.fsencode(output / '0-splits-load-candidate-retry2/runtime.sock')) < 104,
            'output path is too long for a macOS Unix socket')
    binaries = {version: getattr(args, version).resolve() for version in VERSIONS}
    setup_manifest_path = setup_dir / 'manifest.json'
    setup_manifest = json.loads(setup_manifest_path.read_text())
    viewport = setup_manifest.get('viewport')
    require(isinstance(viewport, list) and len(viewport) == 2 and all(value > 0 for value in viewport),
            'setup must specify a fixed viewport')
    require(setup_manifest.get('input_method') == 'key', 'setup must use key input')
    shared = dict(library=setup_dir / 'probe.dylib', config=setup_dir / 'config.lua',
                  ghostty=setup_dir / 'GhosttyProbe.app/Contents/MacOS/ghostty')
    for path in (*binaries.values(), *shared.values()):
        require(path.is_file(), f'missing artifact: {path}')
    require(sha256(tools_dir / 'gui_tui_latency.m') == setup_manifest['probe_sha256']['gui_tui_latency.m'],
            'native probe source differs from the source used to build the setup library')
    require(sha256(shared['config']) == setup_manifest['config_sha256'], 'setup config changed')

    output.mkdir(mode=0o700, parents=True)
    harness = output / 'harness'
    harness.mkdir()
    for name in HARNESS_FILES:
        shutil.copy2(tools_dir / name, harness / name)
    shutil.copy2(Path(__file__).resolve(), output / 'runner.py')
    sys.path.insert(0, str(harness))
    from gui_tui_latency import ProbeFailure, WARMUP, background_load, measure, summarize
    from terminal_bench_report import paired_statistics

    options = SimpleNamespace(samples=args.samples, input_method='key', viewport=viewport,
                              vsync=setup_manifest['vsync'], panes=4, throughput=False,
                              text_pattern=args.text_pattern, background_mib_per_second=args.background_mib_per_second,
                              record_rate_misses=args.record_rate_misses,
                              float_windows='--float-windows' in setup_manifest['command_line'])
    require(not options.float_windows or shutil.which('aerospace'), 'aerospace CLI is unavailable')
    manifest = dict(started_at=time.strftime('%Y-%m-%dT%H:%M:%S%z'), command_line=sys.argv,
                    python=sys.version, rounds=args.rounds, samples=args.samples, warmup=WARMUP,
                    mode=args.mode, cases=args.cases, panes=4, viewport=viewport,
                    text_pattern=args.text_pattern, background_mib_per_second=args.background_mib_per_second,
                    background_rate_scope='per background producer/pane',
                    throughput_target_mib_per_second=args.throughput_target_mib_per_second,
                    ghostty_control=args.ghostty_control,
                    ghostty_control_cases=['single'] if args.ghostty_control else [],
                    record_rate_misses=args.record_rate_misses,
                    rate_miss_policy='Preserve complete samples and rate_met=false without retries or tolerance changes.' if args.record_rate_misses else 'Abort on a rate miss.',
                    order='AB on even rounds, BA on odd rounds; optional single-case Ghostty precedes even rounds and follows odd rounds',
                    setup_python_policy='Python tools may differ; native Objective-C source must match setup',
                    binaries={version: dict(path=str(path), sha256=sha256(path))
                              for version, path in binaries.items()},
                    artifacts={name: dict(path=str(path), sha256=sha256(path))
                               for name, path in shared.items()},
                    harness_sha256={name: sha256(harness / name) for name in HARNESS_FILES},
                    runner_sha256=sha256(output / 'runner.py'),
                    setup_manifest=setup_manifest, setup_manifest_sha256=sha256(setup_manifest_path))
    write_json(output / 'manifest.json', manifest)
    (output / 'processes-before.txt').write_text(
        subprocess.check_output(['ps', '-axo', 'pid,ppid,%cpu,rss,comm'], text=True))
    runs, rejected, expected_geometry = [], [], {}
    rate_misses = []
    context, expected_payload = {}, None
    try:
        for round_index in range(args.rounds):
            order = list(VERSIONS if round_index % 2 == 0 else VERSIONS[::-1])
            for case in args.cases:
                options.case, options.throughput = case, case == 'single'
                case_order = order
                if args.ghostty_control and case == 'single':
                    case_order = ['ghostty'] + order if round_index % 2 == 0 else order + ['ghostty']
                for version in case_order:
                    mode = 'ghostty' if version == 'ghostty' else args.mode
                    binary = binaries['candidate'] if version == 'ghostty' else binaries[version]
                    setup = (binary, setup_dir / 'GhosttyProbe.app',
                             shared['library'], shared['config'], options)
                    retained_rate_miss = False
                    for attempt in range(3):
                        name = f'{round_index}-{case}-{version}' + (f'-retry{attempt}' if attempt else '')
                        directory = output / name
                        context = dict(round=round_index, case=case, version=version,
                                       attempt=attempt, directory=name)
                        try:
                            result = measure(mode, directory, setup)
                            break
                        except ProbeFailure as failure:
                            row = failure.result
                            retryable = row['failed'] == 10 and row.get('panes_created') == 0 and not row['gpu_ms']
                            if not retryable:
                                raise
                            rejected.append(dict(**context, reason='no test window, no timing samples', result=row))
                            write_json(output / 'rejected.json', rejected)
                            if attempt == 2:
                                raise
                        except RuntimeError as error:
                            expected = f'background output missed its requested rate; raw observations retained in {directory / "result.json"}'
                            if not args.record_rate_misses or str(error) != expected:
                                raise
                            result = json.loads((directory / 'result.json').read_text())
                            require(result.get('background_load', {}).get('rate_met') is False,
                                    'rate-miss exception lacks matching evidence')
                            retained_rate_miss = True
                            break
                    binary_hash = manifest['artifacts']['ghostty']['sha256'] if version == 'ghostty' else manifest['binaries'][version]['sha256']
                    result.update(**context, binary_sha256=binary_hash, rate_miss_retained=retained_rate_miss)
                    write_json(directory / 'result.json', result)
                    validate(result, directory, options, WARMUP)
                    require(result['summary'] == summarize(result['gpu_ms'][WARMUP:]), 'summary differs from raw samples')
                    if result.get('background_mib_per_second') is not None:
                        require(result['background_load'] == background_load(result['fixtures'], options.background_mib_per_second),
                                'background load evidence differs from fixture checkpoints')
                        if result['background_load']['rate_met'] is False:
                            rate_misses.append(dict(**context, background_load=result['background_load']))
                            write_json(output / 'rate-misses.json', rate_misses)
                    current_geometry = geometry(result)
                    geometry_key = mode, case
                    if geometry_key in expected_geometry:
                        require(current_geometry == expected_geometry[geometry_key],
                                f'geometry differs across versions or rounds for {geometry_key}: {current_geometry}')
                    else:
                        expected_geometry[geometry_key] = current_geometry
                    if options.throughput:
                        digests = {entry['name']: entry['payload_sha256'] for entry in result['throughput']['cases']}
                        if expected_payload is not None:
                            require(digests == expected_payload, 'payload bytes differ across runs')
                        else:
                            expected_payload = digests
                    runs.append(result)
                    write_json(output / 'runs.json', runs)

        for version, path in binaries.items():
            require(sha256(path) == manifest['binaries'][version]['sha256'], f'binary changed: {version}')
        for name, path in shared.items():
            require(sha256(path) == manifest['artifacts'][name]['sha256'], f'shared artifact changed: {name}')

        paired = {}
        for case in args.cases:
            before = [run for run in runs if run['version'] == 'baseline' and run['case'] == case]
            after = [run for run in runs if run['version'] == 'candidate' and run['case'] == case]
            paired[case] = paired_statistics(before, after)
        throughput = {}
        measured_versions = (*VERSIONS, 'ghostty') if args.ghostty_control else VERSIONS
        for version in measured_versions:
            throughput[version] = {}
            for workload in ('ascii', 'ansi'):
                values = [entry['mib_per_second'] for run in runs
                          if run['version'] == version and run['case'] == 'single'
                          for entry in run['throughput']['cases'] if entry['name'] == workload]
                if values:
                    throughput[version][workload] = dict(rounds=values, median=statistics.median(values),
                        minimum=min(values), maximum=max(values),
                        target_mib_per_second=args.throughput_target_mib_per_second,
                        all_rounds_meet_target=all(value >= args.throughput_target_mib_per_second for value in values))
        write_json(output / 'paired.json', dict(latency=paired, throughput=throughput,
                    note='Latency differences are candidate minus baseline; bootstrap units are complete paired rounds. All retained rate misses are included.',
                    rate_misses=rate_misses,
                    load_note='The target rate is per producer. Identical observed load is not claimed for intervals with rate_met=false.'))
        pooled = {case: {version: summarize([value for run in runs if run['case'] == case and run['version'] == version
                                           for value in run['gpu_ms'][WARMUP:]])
                         for version in measured_versions if any(run['case'] == case and run['version'] == version for run in runs)}
                  for case in args.cases}
        write_json(output / 'summary.json', dict(pooled_latency_ms=pooled, throughput_mib_per_second=throughput,
                   requested_background_mib_per_second=args.background_mib_per_second, rate_misses=rate_misses,
                   background_load_runs=[dict(round=run['round'], case=run['case'], version=run['version'], background_load=run['background_load'])
                                         for run in runs if 'background_load' in run],
                   load_note='All samples are retained. Rate misses preserve their observed throughput and do not establish equal load.'))
        for version in measured_versions:
            write_json(output / f'{version}.json', dict(manifest=dict(manifest, version=version),
                       runs=[run for run in runs if run['version'] == version]))
        write_json(output / 'complete.json', dict(runs=len(runs), rejected_startups=len(rejected), retained_rate_misses=len(rate_misses)))
    except BaseException as error:
        write_json(output / 'failure.json', dict(**context, error_type=type(error).__name__, error=str(error)))
        raise


if __name__ == '__main__':
    main()
