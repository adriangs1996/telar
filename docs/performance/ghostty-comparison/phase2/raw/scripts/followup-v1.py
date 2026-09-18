#!/usr/bin/env python3
"""Serial phase-two diagnostics, sustained throughput and candidate profiling."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import sys
import time

MIB = 1024 * 1024
MAX_SETUP_PTY_BYTES = 4096
BINARIES = {
    'baseline': '/tmp/tgb-phase1-final-verified/bin/telar',
    'candidate': '/tmp/tgb-phase2-final/bin/telar',
    'diagnostic-baseline': '/tmp/tgb-phase1-final-diagnostic/bin/telar',
    'diagnostic-candidate': '/tmp/tgb-phase2-final-diagnostic/bin/telar',
}
TOOLS = ['terminal_runtime_bench.py', 'terminal_bench_fixture.py', 'perf_e2e.py',
         'flood.py', 'echo_latency.py', 'load_latency.py', 'graphics_roundtrip.py']


def save(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(MIB), b''):
            digest.update(chunk)
    return digest.hexdigest()


def plan(repo, output):
    specs = []
    for index, pattern in enumerate(('repeat', 'variable')):
        order = ('baseline', 'candidate') if index == 0 else ('candidate', 'baseline')
        for variant in order:
            specs.append(dict(name=f'diagnostic-{pattern}-{variant}', kind='diagnostic',
                              variant=variant, pattern=pattern, mib=8, settle=3,
                              binary_key=f'diagnostic-{variant}', sampled=False))
    for round_index in range(3):
        order = ('baseline', 'candidate') if round_index % 2 == 0 else ('candidate', 'baseline')
        patterns = ('repeat', 'variable') if round_index % 2 == 0 else ('variable', 'repeat')
        for pattern in patterns:
            for variant in order:
                specs.append(dict(name=f'sustained-{round_index}-{pattern}-{variant}',
                                  kind='sustained', variant=variant, pattern=pattern,
                                  round=round_index, mib=64, settle=0,
                                  binary_key=variant, sampled=False))
    specs.append(dict(name='profile-candidate-repeat', kind='profile', variant='candidate',
                      pattern='repeat', mib=1024, settle=0, binary_key='candidate', sampled=True))
    for spec in specs:
        spec['directory'] = str(output / 'raw' / spec['name'])
        spec['binary'] = str(Path(BINARIES[spec['binary_key']]).resolve())
        spec['command'] = [sys.executable, str(repo / 'tools/terminal_runtime_bench.py'),
                           '--binary', spec['binary'], '--output', spec['directory'],
                           '--mib', str(spec['mib']), '--settle-seconds', str(spec['settle'])]
        if spec['sampled']:
            spec['command'].append('--sample')
    return specs


def diagnostic_summary(directory, result):
    pid = int((directory / 'runtime.pid').read_text())
    path = directory / f'runtime.sock.runtime-{pid}.log'
    rows = []
    for line_number, line in enumerate(path.read_text().splitlines(), 1):
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if value.get('role') == 'runtime':
            rows.append((line_number, value))
    first_load = next(index for index, (_, row) in enumerate(rows)
                      if row.get('pty_bytes', 0) >= MAX_SETUP_PTY_BYTES)
    if first_load == 0:
        raise ValueError('no pre-workload sample; refusing to subtract another process or setup')
    before_line, before = rows[first_load - 1]
    after_line, after = rows[-1]
    expected_bytes = sum(case['bytes'] for case in result['cases'])
    if after['pty_bytes'] - before['pty_bytes'] < expected_bytes:
        raise ValueError('last runtime sample does not cover the complete payload')
    if after.get('attachment_count') != 1 or after.get('pane_count') != 1:
        raise ValueError('last sample was collected after teardown')
    delta = {key: value - before[key] for key, value in after.items()
             if key in before and isinstance(value, (int, float))
             and isinstance(before[key], (int, float))}
    counter_keys = ['pty_events', 'pty_bytes', 'frames', 'frame_bytes', 'frame_cells',
                    'frame_spans', 'snapshots', 'cursor_only_frames', 'noop_frames',
                    'diff_scanned_cells', 'damaged_rows', 'client_messages',
                    'folded_pty_events', 'coalesced_spans', 'coalesced_bytes_saved']
    allocation_keys = [key for key in delta if ('allocs' in key or 'alloc_bytes' in key)
                       and not key.startswith('heap_live')]
    drop_keys = [key for key in delta if 'dropped' in key or key.endswith('_drops')]
    queue_keys = [key for key in after if 'queue' in key and
                  any(key.endswith(suffix) for suffix in ('_depth', '_events', '_bytes', '_high_water'))
                  and 'dropped' not in key]
    memory_keys = [key for key in ('rss_bytes', 'heap_live_bytes', 'heap_live_allocs',
                                  'vt_scrollback_bytes', 'vt_screen_bytes') if key in after]
    window = [row for _, row in rows[first_load - 1:]]
    gauges = {key: dict(before=before[key], after=after[key], delta=delta[key],
                       sampled_max=max(row[key] for row in window if key in row))
              for key in memory_keys + queue_keys}
    return dict(runtime_pid=pid, log=str(path), before_line=before_line, after_line=after_line,
                before=before, after=after, delta=delta,
                counters={key: delta[key] for key in counter_keys if key in delta},
                allocations={key: delta[key] for key in allocation_keys},
                drops={key: delta[key] for key in drop_keys}, gauges=gauges,
                scope='same-process last pre-load sample to last post-settle sample',
                limitations=['Runtime logs sample roughly once per second; sampled maxima are not peak guarantees.',
                             'frame_bytes counts encoded cell frames, not all socket bytes or host-terminal output.',
                             'Instrumented allocations exclude std.Io tasks and uninstrumented library allocators.',
                             'RSS includes process state beyond the tracked heap; samples include the settling window.',
                             'Queue high-water values are lifetime gauges, not additive counters.'])


def summarize(records):
    diagnostics = {}
    sustained = {}
    for record in records:
        if not record.get('valid'):
            continue
        if record['kind'] == 'diagnostic':
            try:
                diagnostics[record['name']] = diagnostic_summary(Path(record['directory']), record['result'])
            except Exception as error:
                diagnostics[record['name']] = dict(error=f'{type(error).__name__}: {error}',
                                                  raw_directory=record['directory'])
        if record['kind'] == 'sustained':
            for case in record['result']['cases']:
                key = f"{record['pattern']}/{record['variant']}/{case['name']}"
                sustained.setdefault(key, []).append(dict(round=record['round'],
                    mib_per_second=case['mib_per_second'], directory=record['directory']))
    rates = {}
    for key, values in sustained.items():
        sample = [value['mib_per_second'] for value in values]
        rates[key] = dict(n=len(sample), median=statistics.median(sample), min=min(sample),
                          max=max(sample), runs=values)
    return dict(diagnostics=diagnostics, sustained=rates,
                profile=[record for record in records if record['kind'] == 'profile'],
                completed_runs=len(records), valid_runs=sum(record.get('valid', False) for record in records),
                endpoint='PTY write to DSR response; not GPU completion or presentation',
                pairing='Sustained baseline/candidate are paired by pattern and round; order AB, BA, AB.',
                diagnostics_scope='One run per variant/pattern; instrumented counts, not throughput ranking.')


def recovery_cleanup(proc, spec, env, perf_e2e):
    cleanup_env = dict(env, TELAR_SOCKET_PATH=str(Path(spec['directory']) / 'runtime.sock'))
    roots = [proc.pid] + perf_e2e.runtime_pids(cleanup_env['TELAR_SOCKET_PATH'])
    sessions = perf_e2e.owned_sessions(perf_e2e.descendants(roots))
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
    shutdown = perf_e2e.stop_runtime(spec['binary'], cleanup_env)
    survivors = perf_e2e.session_members(sessions)
    perf_e2e.cleanup_sessions(sessions)
    return dict(shutdown=shutdown, forced_cleanup=survivors,
                remaining=perf_e2e.session_members(sessions))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=Path('/Users/adriangonzalez/sandbox/telar'))
    parser.add_argument('--output', type=Path, default=Path('/tmp/tgb-p2-followup'))
    parser.add_argument('--summarize-only', action='store_true')
    args = parser.parse_args()
    repo, output = args.repo.resolve(), args.output.resolve()
    if args.summarize_only:
        save(output / 'summary.json', summarize(json.loads((output / 'runs.json').read_text())))
        return 0
    output.mkdir(mode=0o700)
    (output / 'raw').mkdir()
    (output / 'logs').mkdir()
    (output / 'scripts').mkdir()
    sys.path.insert(0, str(repo / 'tools'))
    import perf_e2e

    specs = plan(repo, output)
    sources = [repo / 'tools' / name for name in TOOLS]
    sources += [repo / 'docs/performance/ghostty-comparison/config.lua', Path(__file__).resolve()]
    manifest = dict(created_unix_ns=time.time_ns(), platform=platform.platform(), python=sys.version,
                    binaries={name: dict(path=str(Path(path).resolve()), sha256=sha256(Path(path)))
                              for name, path in BINARIES.items()},
                    tools={str(path): sha256(path) for path in sources}, plan=specs,
                    pattern_environment='BENCH_TEXT_PATTERN', outer_pty=[111, 35], expected_inner_pty=[111, 33],
                    profiler='sample runtime and client for 8 seconds at 1ms; repeat corpus generated/hashed before timing',
                    all_workloads_serial=True)
    for path in sources:
        shutil.copy2(path, output / 'scripts' / path.name)
    save(output / 'manifest.json', manifest)
    records = []
    expected_hashes = {}
    for spec in specs:
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(('TELAR_', 'BENCH_', 'TMUX', 'HERDR'))}
        env['BENCH_TEXT_PATTERN'] = spec['pattern']
        record = dict(spec, started_unix_ns=time.time_ns(), valid=False)
        started = time.perf_counter()
        failure = None
        with (output / 'logs' / f"{spec['name']}.log").open('wb') as log:
            proc = subprocess.Popen(spec['command'], cwd=repo, env=env, stdout=log,
                                    stderr=subprocess.STDOUT, start_new_session=True)
            try:
                record['returncode'] = proc.wait(timeout=240)
                directory = Path(spec['directory'])
                record['result'] = json.loads((directory / 'result.json').read_text())
                record['shutdown'] = json.loads((directory / 'shutdown.json').read_text())
                result, shutdown = record['result'], record['shutdown']
                if record['returncode'] or result.get('failed') or len(result['cases']) != 2:
                    raise RuntimeError('workload failed or did not finish both cases')
                if shutdown['returncode'] or not all(shutdown.get(key) for key in
                       ('exited', 'children_exited', 'socket_removed', 'cleanup_complete')):
                    raise RuntimeError('runtime cleanup was not graceful and complete')
                if result.get('text_pattern') != spec['pattern']:
                    raise RuntimeError('fixture did not consume the selected text pattern')
                for case in result['cases']:
                    if case['bytes'] != spec['mib'] * MIB or [case['cols'], case['rows']] != [111, 33]:
                        raise RuntimeError('payload length or PTY geometry differs from the plan')
                    key = (spec['pattern'], spec['mib'], case['name'])
                    digest = case['payload_sha256']
                    if expected_hashes.setdefault(key, digest) != digest:
                        raise RuntimeError('same-case payload hash changed between runs')
                if spec['sampled']:
                    record['profile_ascii_elapsed_ms'] = result['cases'][0]['elapsed_ms']
                    record['profile_note'] = 'Profiler starts before corpus hashing; inspect samples before attributing active-work fractions.'
                record['valid'] = True
            except BaseException as error:
                failure = f'{type(error).__name__}: {error}'
                record['error'] = failure
                record['recovery'] = recovery_cleanup(proc, spec, env, perf_e2e)
        record['elapsed_seconds'] = time.perf_counter() - started
        records.append(record)
        save(output / 'runs.json', records)
        save(output / 'summary.json', summarize(records))
        print(json.dumps({key: record[key] for key in ('name', 'valid', 'elapsed_seconds')}), flush=True)
        if failure:
            print(failure, file=sys.stderr, flush=True)
            return 1
    manifest['completed_unix_ns'] = time.time_ns()
    manifest['binaries_unchanged'] = all(sha256(Path(value['path'])) == value['sha256']
                                         for value in manifest['binaries'].values())
    manifest['tools_unchanged'] = all(sha256(Path(path)) == digest for path, digest in manifest['tools'].items())
    save(output / 'manifest.json', manifest)
    return 0 if manifest['binaries_unchanged'] and manifest['tools_unchanged'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
