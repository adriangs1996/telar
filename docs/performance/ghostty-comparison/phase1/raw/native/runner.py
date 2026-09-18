#!/usr/bin/env python3
"""Run paired Telar GUI measurements using an already-built native probe.

Example:
  python3 /tmp/tgb-phase1-native-ab.py --baseline /tmp/old/bin/telar \
    --candidate /tmp/new/bin/telar --setup-dir /tmp/native-setup \
    --output /tmp/native-ab --tools tools --rounds 4 --samples 100

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
    require(result['viewport'] == options.viewport, 'GUI render target changed')
    require(len(result['fixtures']) == expected_panes, 'incorrect fixture count')
    for fixture in result['fixtures']:
        require(fixture['background'] == ('idle' if options.case == 'single' else 'flood'),
                'background workload changed')
    if options.throughput:
        measured = result['throughput']
        require(measured['endpoint'] == 'pty_write_to_dsr_response', 'throughput endpoint changed')
        for case in measured['cases']:
            require([case['cols'], case['rows']] == result['pty_cells'],
                    'throughput and latency PTY geometry differ')
            require(math.isfinite(case['mib_per_second']) and case['mib_per_second'] > 0,
                    'invalid throughput rate')
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
    args = parser.parse_args()
    if not 1 <= args.rounds <= 10 or not 1 <= args.samples <= 400:
        parser.error('rounds must be 1..10 and samples 1..400')

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
    for name, expected_hash in setup_manifest['probe_sha256'].items():
        require(sha256(tools_dir / name) == expected_hash, f'setup and tools disagree: {name}')

    output.mkdir(mode=0o700, parents=True)
    harness = output / 'harness'
    harness.mkdir()
    for name in HARNESS_FILES:
        shutil.copy2(tools_dir / name, harness / name)
    shutil.copy2(Path(__file__).resolve(), output / 'runner.py')
    sys.path.insert(0, str(harness))
    from gui_tui_latency import ProbeFailure, WARMUP, measure
    from terminal_bench_report import paired_statistics

    options = SimpleNamespace(samples=args.samples, input_method='key', viewport=viewport,
                              vsync=setup_manifest['vsync'], panes=4, throughput=False,
                              float_windows='--float-windows' in setup_manifest['command_line'])
    require(not options.float_windows or shutil.which('aerospace'), 'aerospace CLI is unavailable')
    manifest = dict(started_at=time.strftime('%Y-%m-%dT%H:%M:%S%z'), command_line=sys.argv,
                    python=sys.version, rounds=args.rounds, samples=args.samples, warmup=WARMUP,
                    mode='gui', cases=CASES, panes=4, viewport=viewport, order='AB on even rounds, BA on odd rounds',
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
    context = {}
    try:
        for round_index in range(args.rounds):
            order = VERSIONS if round_index % 2 == 0 else VERSIONS[::-1]
            for case in CASES:
                options.case, options.throughput = case, case == 'single'
                for version in order:
                    setup = (binaries[version], setup_dir / 'GhosttyProbe.app',
                             shared['library'], shared['config'], options)
                    for attempt in range(3):
                        name = f'{round_index}-{case}-{version}' + (f'-retry{attempt}' if attempt else '')
                        directory = output / name
                        context = dict(round=round_index, case=case, version=version,
                                       attempt=attempt, directory=name)
                        try:
                            result = measure('gui', directory, setup)
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
                    result.update(**context, binary_sha256=manifest['binaries'][version]['sha256'])
                    write_json(directory / 'result.json', result)
                    validate(result, directory, options, WARMUP)
                    current_geometry = geometry(result)
                    if case in expected_geometry:
                        require(current_geometry == expected_geometry[case],
                                f'geometry differs across versions or rounds for {case}: {current_geometry}')
                    else:
                        expected_geometry[case] = current_geometry
                    runs.append(result)
                    write_json(output / 'runs.json', runs)

        for version, path in binaries.items():
            require(sha256(path) == manifest['binaries'][version]['sha256'], f'binary changed: {version}')
        for name, path in shared.items():
            require(sha256(path) == manifest['artifacts'][name]['sha256'], f'shared artifact changed: {name}')

        paired = {}
        for case in CASES:
            before = [run for run in runs if run['version'] == 'baseline' and run['case'] == case]
            after = [run for run in runs if run['version'] == 'candidate' and run['case'] == case]
            paired[case] = paired_statistics(before, after)
        throughput = {}
        for version in VERSIONS:
            throughput[version] = {}
            for workload in ('ascii', 'ansi'):
                values = [entry['mib_per_second'] for run in runs
                          if run['version'] == version and run['case'] == 'single'
                          for entry in run['throughput']['cases'] if entry['name'] == workload]
                throughput[version][workload] = dict(rounds=values, median=statistics.median(values),
                    minimum=min(values), maximum=max(values), all_rounds_at_least_40=all(value >= 40 for value in values))
        write_json(output / 'paired.json', dict(latency=paired, throughput=throughput,
                    note='Latency differences are candidate minus baseline; bootstrap units are complete paired rounds.'))
        for version in VERSIONS:
            write_json(output / f'{version}.json', dict(manifest=dict(manifest, version=version),
                       runs=[run for run in runs if run['version'] == version]))
        write_json(output / 'complete.json', dict(runs=len(runs), rejected_startups=len(rejected)))
    except BaseException as error:
        write_json(output / 'failure.json', dict(**context, error_type=type(error).__name__, error=str(error)))
        raise


if __name__ == '__main__':
    main()
