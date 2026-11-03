#!/usr/bin/env python3
"""Observe native history query replacements against two verified BGRA templates.

Requires macOS with the Metal4 SDK, clang and Pillow. Uses independent owned runtime/GUI processes and same-submission
Metal/Metal4 readback. Supply a standalone SQLite fixture, shared configuration,
and a case JSON containing viewport, drawable, region and two {text, template}
entries. Templates must come from independently checked result captures; this
observer does not establish ranking correctness or cross-renderer visual parity.
"""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'services/gui-cpp/tools'))
import capture_history as capture
from benchmark_host import HostLoadGate
from bench_stack import executable_identity, process_identity, runtime_identity, staged_runtime
from native_runtime_resources import interval, snapshot
from perf_e2e import isolated_environment, stop_runtime
from history_query_trace import HistoryQueryTrace


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def load_case(path, output, timeout):
    case = json.loads(path.read_text())
    for name, count in (('viewport', 2), ('drawable', 2), ('region', 4)):
        values = case.get(name)
        if not isinstance(values, list) or len(values) != count or any(type(value) is not int for value in values):
            raise ValueError(f'{name} must contain {count} integers')
    width, height = case['drawable']
    x, y, region_width, region_height = case['region']
    if not all(1 <= value <= 8192 for value in [width, height, *case['viewport']]):
        raise ValueError('Invalid drawable/viewport size')
    if not (0 <= x < width and 0 <= y < height and 0 < region_width <= width-x and 0 < region_height <= height-y):
        raise ValueError('The ROI must fit inside the drawable')
    expected_bytes = region_width * region_height * 4
    if expected_bytes > 1024 * 1024:
        raise ValueError('The packed ROI is limited to 1 MiB')
    queries = case.get('queries')
    if not isinstance(queries, list) or len(queries) != 2:
        raise ValueError('Exactly two query/template entries are required')
    pixels = []
    for index, entry in enumerate(queries):
        text = entry.get('text')
        if not isinstance(text, str) or not text or len(text.encode('utf-8')) > 128 or any(ord(char) < 32 for char in text):
            raise ValueError('Query text must be nonempty, printable and at most 128 UTF-8 bytes')
        source = Path(entry['template'])
        if not source.is_absolute():
            source = path.parent / source
        data = source.read_bytes()
        if len(data) != expected_bytes:
            raise ValueError('Template byte count does not match the BGRA ROI')
        pixels.append(data)
        target = output / f'template-{index}.bgra'
        target.write_bytes(data)
        entry['template'] = str(target)
        entry['sha256'] = hashlib.sha256(data).hexdigest()
    if queries[0]['text'] == queries[1]['text'] or pixels[0] == pixels[1]:
        raise ValueError('Queries and result templates must both differ')
    case['timeout_seconds'] = timeout
    save(output / 'case.json', case)
    return case


def prepare(output):
    capture.prepare_probe(output)
    shutil.copy2(ROOT / 'services/gui-cpp/tools/history_query_trace.py', output / 'history_query_trace.py')
    source = output / 'history_actions.m'
    source.write_text(source.read_text().replace('[timer invalidate]; [window close]; return;', '[timer invalidate]; return;'))
    capture.compile_probe(source, output / 'actions.dylib')
    shutil.copy2(ROOT / 'tools/gui_history_latency.m', output / 'gui_history_latency.m')
    observer_build = ['clang', '-O2', '-dynamiclib', '-fobjc-arc', '-framework', 'AppKit', '-framework', 'Metal',
                      '-framework', 'QuartzCore', '-I', str(ROOT / 'tools'), str(output / 'gui_history_latency.m'), '-o', str(output / 'observer.dylib')]
    subprocess.run(observer_build, check=True)
    save(output / 'observer-build.json', observer_build)
    helper = output / 'resource-snapshot'
    subprocess.run(['clang', '-O2', str(ROOT / 'tools/macos_process_resources.c'), '-o', str(helper)], check=True)
    return helper


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--kind', choices=('cpp', 'zig'), required=True)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--gui', type=Path, required=True)
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--fixture', type=Path, required=True)
    parser.add_argument('--case', type=Path, required=True)
    parser.add_argument('--qt-prefix', type=Path)
    parser.add_argument('--samples', type=int, default=60)
    parser.add_argument('--timeout', type=float, default=75)
    parser.add_argument('--negative', choices=('stale', 'missing', 'zero', 'callback', 'late-stale'))
    parser.add_argument('--diagnostic', action='store_true')
    parser.add_argument('--observe-only', action='store_true')
    parser.add_argument('--max-load', type=float, nargs=2)
    parser.add_argument('--burst-ms', type=float, default=0, help='Offer individual composed characters at independent fixed deadlines (1..250 ms)')
    parser.add_argument('--burst-main-stall-ms', type=float, default=0, help='Diagnostic main-thread stall after offering a burst (0..500 ms)')
    parser.add_argument('--callback-drain-ms', type=float, default=50, help='Observe the final result for 50..1000 ms before the next trial')
    parser.add_argument('--trace-history', action='store_true', help='Trace history requests through an isolated diagnostic relay')
    parser.add_argument('--delay-history', action='append', default=[], metavar='QUERY=MS', help='Delay matching history replies by 0..1000 ms; implies --trace-history')
    options = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('Native Metal presentation observation requires macOS')
    if not 1 <= options.samples <= 10000 or not 5 <= options.timeout <= 3600:
        parser.error('Samples must be 1..10000 and timeout 5..3600 seconds')
    if options.observe_only and options.negative:
        parser.error('Negative controls require query replacement mode')
    if not (options.burst_ms == 0 or 1 <= options.burst_ms <= 250) or not 0 <= options.burst_main_stall_ms <= 500 or not 50 <= options.callback_drain_ms <= 1000:
        parser.error('Invalid burst interval, diagnostic stall or callback drain')
    if (options.burst_main_stall_ms and not options.burst_ms) or (options.observe_only and options.burst_ms):
        parser.error('A burst stall requires burst input, which requires replacement observation')
    delays = {}
    try:
        for value in options.delay_history:
            query, milliseconds = value.rsplit('=', 1)
            delay = float(milliseconds)
            if not 0 <= delay <= 1000:
                raise ValueError('delay out of range')
            delays[query] = delay / 1000
    except ValueError:
        parser.error('--delay-history requires QUERY=MS with 0..1000 milliseconds')
    output = options.output.resolve()
    output.mkdir(mode=0o700, exist_ok=False)
    (output / 'work').mkdir()
    shutil.copy2(__file__, output / 'driver.py')
    case = load_case(options.case.resolve(), output, options.timeout)
    if options.burst_ms and any((len(entry['text']) - 1) * options.burst_ms + options.burst_main_stall_ms > 1000 for entry in case['queries']):
        parser.error('Each burst must fit within one second of the two-second trial deadline')
    case.update(burst_interval_ms=options.burst_ms, burst_main_stall_ms=options.burst_main_stall_ms,
                callback_drain_ms=options.callback_drain_ms)
    save(output / 'case.json', case)
    helper = prepare(output)
    shutil.copy2(options.config, output / 'gui.lua')
    runtime, gui = options.runtime.resolve(), options.gui.resolve()
    directory = output / 'client'
    env = isolated_environment(directory)
    env.update(TELAR_HISTORY=str(directory / 'history.db'), TELAR_SOCKET=env['TELAR_SOCKET_PATH'])
    # SQLite's backup reads a consistent fixture even when it has a WAL sidecar.
    with sqlite3.connect(options.fixture.resolve().as_uri() + '?mode=ro', uri=True) as source:
        with sqlite3.connect(env['TELAR_HISTORY']) as target:
            source.backup(target)
    for name in tuple(env):
        if name.startswith(('DYLD_', 'QT_', 'QSG_', 'QML_')) or name in ('SSH_CONNECTION', 'SSH_TTY', 'SSH_CLIENT'):
            env.pop(name)
    env.update(QT_QPA_PLATFORM='cocoa', QSG_RHI_BACKEND='metal')
    if options.qt_prefix:
        qt = options.qt_prefix.resolve()
        env.update(QT_PLUGIN_PATH=str(qt / 'plugins'), QML_IMPORT_PATH=str(qt / 'qml'))
    settings = argparse.Namespace(viewport=case['viewport'], inspect=False, scope='global', failed=False,
                                  query=case['queries'][0]['text'], author='human', selected_row=0,
                                  inspection_pages=0, select_prefix=None, select_all=False, left=0, preedit=None,
                                  commit=None, wheel_events=[], escape_count=0, refresh_viewport=False)
    capture.script(directory, settings)
    actions_path = directory / 'actions.json'
    actions = json.loads(actions_path.read_text())
    end = next(i for i, action in enumerate(actions) if action.get('signal') == str(directory / 'settled.at'))
    save(actions_path, actions[:end + 1])
    command = [str(gui), 'gui', '--config', str(output / 'gui.lua'), '/bin/sh'] if options.kind == 'zig' else [
        str(gui), '--fresh', '--config', str(output / 'gui.lua'), '--smoke-ms', str(int((options.timeout + 10)*1000)), '/bin/sh']
    manifest = dict(scope='Native result observer; instrumented timing only, not independent ranking, visual parity or native120 acceptance.',
                    kind=options.kind, command=command, runtime=executable_identity(runtime), gui=executable_identity(gui),
                    helper=staged_runtime(gui, runtime), resource_helper=executable_identity(helper), case=case,
                    samples=options.samples, negative=options.negative, diagnostic=options.diagnostic, observe_only=options.observe_only,
                    trace_history=options.trace_history or bool(delays), reply_delays=delays,
                    sources={name: capture.sha(output / name) for name in ('driver.py', 'history_actions.m', 'gui_history_latency.m', 'gui_view.h', 'history_capture_proxy.py', 'history_query_trace.py')},
                    observer_sha256=capture.sha(output / 'observer.dylib'),
                    config_sha256=capture.sha(output / 'gui.lua'), fixture_sha256=capture.sha(Path(env['TELAR_HISTORY'])))
    save(output / 'manifest.json', manifest)
    host = HostLoadGate(output / 'host-load.json', options.max_load)
    with host.run('native-history'):
        process = None
        proxy = None
        try:
            started = subprocess.run([str(runtime), 'server', '--background', '--no-config', *(['--no-session'] if options.kind == 'cpp' else [])],
                                     env=env, cwd=output / 'work', capture_output=True, text=True, timeout=15)
            (directory / 'start.log').write_text(started.stdout + started.stderr)
            started.check_returncode()
            identity = runtime_identity(env['TELAR_SOCKET_PATH'], runtime)
            save(directory / 'runtime-identity.json', identity)
            assert identity['sha256'] == manifest['runtime']['sha256']
            launch = dict(env, DYLD_INSERT_LIBRARIES=str(output / 'actions.dylib') + ':' + str(output / 'observer.dylib'),
                          TELAR_GUI_ACTIONS=str(actions_path), TELAR_HISTORY_OBSERVER=str(directory / 'observations.json'),
                          TELAR_HISTORY_CASE=str(output / 'case.json'))
            if options.trace_history or delays:
                proxy = HistoryQueryTrace(env['TELAR_SOCKET_PATH'], directory, delays)
                endpoint = str(proxy.start())
                launch.update(TELAR_SOCKET=endpoint, TELAR_SOCKET_PATH=endpoint)
            if not options.observe_only:
                launch.update(TELAR_HISTORY_TIMING=str(options.samples), TELAR_HISTORY_SETTLED=str(directory / 'settled.at'),
                              TELAR_HISTORY_READY=str(directory / 'ready'), TELAR_HISTORY_RELEASE=str(directory / 'release'))
            if options.negative:
                launch['TELAR_HISTORY_NEGATIVE'] = options.negative
            if options.diagnostic:
                launch['TELAR_HISTORY_DIAGNOSTIC'] = '1'
            before = None
            floated = []
            with (directory / 'launch.log').open('w') as log:
                process = subprocess.Popen(command, env=launch, cwd=output / 'work', stdout=log, stderr=subprocess.STDOUT)
                actual = process_identity(process.pid)
                assert actual['path'] == str(gui) and actual['sha256'] == manifest['gui']['sha256']
                save(directory / 'gui-identity.json', actual)
                deadline = time.monotonic() + options.timeout + 5
                while process.poll() is None and time.monotonic() < deadline:
                    if not floated and before is None:
                        capture.float_owned_windows(process, floated)
                    if before is None and (directory / 'ready').exists():
                        before = {name: snapshot(helper, pid) for name, pid in (('gui', process.pid), ('runtime', identity['pid']))}
                        (directory / 'release').write_text('release\n')
                    if (directory / 'settled.at').exists() and (directory / 'observations.json').exists():
                        recorded = json.loads((directory / 'observations.json').read_text())
                        if 'passed' in recorded or (options.observe_only and any(row['matched'] == settings.query for row in recorded['frames'])):
                            break
                    time.sleep(.05)
            if process.poll() is not None or not (directory / 'settled.at').exists():
                raise RuntimeError(f'Native history setup did not remain ready: GUI exit={process.poll()}')
            recorded = json.loads((directory / 'observations.json').read_text())
            if options.observe_only:
                matches = [row for row in recorded['frames'] if row['matched'] == settings.query]
                assert all(row['dropped_count'] == 0 for row in recorded['frames'])
                assert matches and all(row['presented_time'] > 0 and row['active'] and row['key_window'] and row['view_points'] == settings.viewport and row['input_text'] == settings.query for row in matches)
                assert (directory / 'observations.json.first.bgra').read_bytes() == Path(case['queries'][0]['template']).read_bytes()
                result = dict(qualification_passed=True, performance_eligible=False, matching_frames=len(matches), raw_bytes_equal=True)
            else:
                assert before is not None
                after = {name: snapshot(helper, pid) for name, pid in (('gui', process.pid), ('runtime', identity['pid']))}
                resources = {name: dict(start=before[name], end=after[name], interval=interval(before[name], after[name])) for name in before}
                save(output / 'resources.json', resources)
                if options.negative == 'callback':
                    assert not recorded['passed'] and recorded['callback_suppressed'] and recorded['pending_submissions'] > 0, recorded
                    assert recorded['last_trial_had_verified_result'] and recorded['error'] == 'Submitted drawables did not complete their pixel/presentation callbacks', recorded
                elif options.negative == 'late-stale':
                    assert not recorded['passed'] and recorded['late_stale_injected'] and recorded['last_trial_had_verified_result'], recorded
                    assert recorded['error'] == 'A stale result replaced the completed query', recorded
                elif options.negative:
                    assert not recorded['passed'] and recorded['error'] == 'No positively presented new result before timeout', recorded
                else:
                    assert recorded['passed'] and recorded['pending_submissions'] == 0 and len(recorded['trials']) == options.samples, recorded
                    assert all(row['presented_time'] > row['input_time'] and row['latency_ms'] > 0 for row in recorded['trials'])
                    assert [row['query'] for row in recorded['trials']] == [case['queries'][(i+1) % 2]['text'] for i in range(options.samples)]
                    if options.burst_ms:
                        for trial in recorded['trials']:
                            inputs = trial['burst_inputs']
                            assert ''.join(row['text'] for row in inputs) == trial['query']
                            assert inputs[-1]['input_text'] == trial['query'] and inputs[-1]['delivered_time'] == trial['input_time']
                            assert all(row['offered_time'] <= row['enqueued_time'] <= row['delivered_time'] for row in inputs)
                        inputs = [row for trial in recorded['trials'] for row in trial['burst_inputs']]
                        recorded['maximum_producer_lag_ms'] = max((row['enqueued_time'] - row['offered_time']) * 1000 for row in inputs)
                        recorded['maximum_main_queue_delay_ms'] = max((row['delivered_time'] - row['enqueued_time']) * 1000 for row in inputs)
                        spans = []
                        for trial in recorded['trials']:
                            events = trial['burst_inputs']
                            if len(events) > 1:
                                offered = events[-1]['offered_time'] - events[0]['offered_time']
                                spans.append({name: abs((events[-1][name] - events[0][name]) / offered - 1)
                                              for name in ('enqueued_time', 'delivered_time')})
                        recorded['burst_span_errors'] = spans
                        recorded['burst_offered_rate_qualified'] = bool(spans) and all(max(row.values()) <= .05 for row in spans)
                        if options.burst_main_stall_ms:
                            assert recorded['maximum_main_queue_delay_ms'] >= options.burst_main_stall_ms / 2
                result = dict(qualification_passed=True, **recorded)
            if proxy is not None:
                trace = proxy.record()
                assert not trace['errors'], trace
                assert trace['queries'] and trace['responses'], trace
                save(output / 'history-trace.json', trace)
            save(output / 'result.json', result)
            print(json.dumps({key: value for key, value in result.items() if key != 'trials'}), flush=True)
        finally:
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            try:
                if proxy is not None:
                    proxy.stop()
            finally:
                cleanup = stop_runtime(runtime, env)
                save(directory / 'cleanup.json', cleanup)
                assert all(cleanup[key] for key in ('cleanup_complete', 'children_exited', 'exited'))
    host.finish()


if __name__ == '__main__':
    main()
