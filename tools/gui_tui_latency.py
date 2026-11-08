#!/usr/bin/env python3
"""Compare terminal GUIs at verified GPU completion or Metal drawable presentation.

The name is historical: the Telar TUI mode left with the TUI, and published
performance records still name this file.

Resigns a private copy of Ghostty; never modifies the installed application.
The probe reads back one marker pixel within the rendering command buffer.
Metal and Metal 4 instrumentation have different overheads.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import signal
import statistics
import subprocess
import time

from terminal_bench_report import latency_samples, validate_telar_display_sync
from terminal_bench_fixture import background_rate
from bench_stack import (descendants, executable_identity, percentile, process_identity, runtime_identity,
                         staged_runtime, stop_runtime)
from benchmark_host import HostLoadGate, HostLoadRejected

WARMUP = 20
BACKGROUND_RATE_TOLERANCE = .05
MODE_GROUPS = dict(native=['ghostty', 'gui-cpp'])
TELAR_MODES = ('gui-cpp',)


def runtime_program(mode, cpp_runtime):
    if mode == 'gui-cpp':
        if cpp_runtime is None:
            raise ValueError('C++ GUI measurements require an explicit runtime')
        return cpp_runtime
    return None


def client_command(mode, cpp_gui, config, fixture):
    if mode == 'ghostty':
        return fixture
    if mode == 'gui-cpp':
        return [str(cpp_gui), '--fresh', '--config', str(config)] + fixture

    raise ValueError(f'unknown GUI mode: {mode}')


def validate_image_receipt(result, size):
    fixtures = result['fixtures']
    if len(fixtures) != 1 or fixtures[0]['role'] != 'primary':
        raise ValueError('image measurement requires exactly one primary fixture')
    image = fixtures[0].get('image', {})
    transport = result.get('image_transport', 'shared-memory')
    if transport not in ('shared-memory', 'inline'):
        raise ValueError('unknown image transport')
    pattern = result.get('image_pattern', 'opaque')
    from image_patterns import placement
    expected_cells = placement(size, pattern)
    if (image.get('pattern', 'opaque') != pattern
            or image.get('placement_cells') != (list(expected_cells) if expected_cells else None)):
        raise ValueError('image receipt does not match the requested pattern and placement')
    if ([image.get('width'), image.get('height')] != list(size)
            or image.get('bytes_per_image') != size[0] * size[1] * 4
            or image.get('format') != 'RGBA8888'
            or image.get('transport') != 'kitty-' + transport):
        raise ValueError('image receipt does not match the requested dimensions and format')
    publications = image.get('publications', [])
    count = len(latency_samples(result))
    if (not publications or fixtures[0].get('marker_inputs') != count
            or {row['input_sequence'] for row in publications} != set(range(count + 1))
            or any(row['generation'] != index + 1 or row['written_ns'] < row['started_ns']
                   or (row['input_sequence'] > 0 and row['color'] != row['input_sequence'] % 2)
                   for index, row in enumerate(publications))
            or any(right['started_ns'] <= left['written_ns'] for left, right in zip(publications, publications[1:]))):
        raise ValueError('image publications do not cover the native input sequence')
    digests = image.get('payload_sha256', [])
    if len(digests) != 3 or len(set(digests)) != 3 or any(
            len(digest) != 64 or any(letter not in '0123456789abcdef' for letter in digest) for digest in digests):
        raise ValueError('image payload digests are incomplete')


def finish_image_fixture(directory, runtime_pid):
    owned = descendants([runtime_pid])
    receipts = list((directory / 'receipts').glob('*.json'))
    if not receipts:
        return
    if len(receipts) != 1:
        raise ValueError('image cleanup requires exactly one fixture')
    fixture_pid = json.loads(receipts[0].read_text())['pid']
    if fixture_pid in owned:
        arguments = shlex.split(owned[fixture_pid][2])
        expected = str(Path(__file__).with_name('image_bench_fixture.py').resolve())
        if expected not in arguments or str(directory) not in arguments or fixture_pid == runtime_pid:
            raise ValueError('image fixture is not the expected owned process')
        try:
            os.kill(fixture_pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 2
    receipt = directory / 'image-cleanup.json'
    while not receipt.is_file() and time.monotonic() < deadline:
        time.sleep(.01)
    if not receipt.is_file():
        raise RuntimeError('image fixture did not finish its receipt and shared-memory cleanup')
    cleanup = json.loads(receipt.read_text())
    if cleanup.get('pid') != fixture_pid or cleanup.get('complete') is not True:
        raise ValueError('image cleanup receipt does not identify the fixture')


class ProbeFailure(RuntimeError):
    def __init__(self, mode, result):
        self.result = result
        super().__init__(f'{mode} probe failed ({result["failed"]}): '
                         f'{result.get("error", "incomplete samples")}; '
                         f'{len(result["gpu_ms"])} responses completed')


def summarize(values):
    return dict(n=len(values), p50_ms=statistics.median(values),
                p95_ms=percentile(values, .95), p99_ms=percentile(values, .99),
                max_ms=max(values))


def aggregate_runs(results, cases, modes):
    aggregate = {}
    for case in cases:
        for mode in modes:
            summaries = [summarize(latency_samples(result)[WARMUP:]) for result in results
                         if result['mode'] == mode and result['case'] == case]
            aggregate[f'{case}/{mode}'] = dict(
                runs=len(summaries), n=sum(row['n'] for row in summaries),
                **{key: statistics.median(row[key] for row in summaries)
                   for key in ('p50_ms', 'p95_ms', 'p99_ms', 'max_ms')})

    return aggregate


def background_load(fixtures, requested_rate):
    observed = []
    for fixture in fixtures:
        if fixture['role'] != 'background':
            continue
        progress = fixture.get('background_progress', [])
        if any(right['at_ns'] <= left['at_ns'] or right['emitted_bytes'] <= left['emitted_bytes']
               for left, right in zip(progress, progress[1:])):
            raise ValueError(f'background progress is not strictly increasing: {fixture["pid"]}')
        rates = [(right['emitted_bytes'] - left['emitted_bytes']) / (right['at_ns'] - left['at_ns']) * 1e9 / (1024 * 1024)
                 for left, right in zip(progress, progress[1:])]
        met = bool(rates) and all(abs(rate / requested_rate - 1) <= BACKGROUND_RATE_TOLERANCE for rate in rates)
        observed.append(dict(pid=fixture['pid'], requested_mib_per_second=requested_rate,
                             observed_mib_per_second=rates, rate_met=met,
                             max_write_ms=fixture.get('background_max_write_ms')))
    return dict(endpoint='bytes accepted by background PTY writes',
                scope='periodic background checkpoints, not synchronized to echo samples',
                rate_scope='per background producer/pane',
                relative_tolerance=BACKGROUND_RATE_TOLERANCE,
                rate_met=bool(observed) and all(row['rate_met'] for row in observed), fixtures=observed)


def cleanup_host(app):
    executable = str(app / 'Contents/MacOS/ghostty')
    for attempt in range(3):
        rows = subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True).splitlines()
        matches = [int(fields[0]) for row in rows if len(fields := row.strip().split(None, 1)) == 2
                   and (fields[1] == executable or fields[1].startswith(executable + ' '))]
        if not matches:
            return
        for pid in matches:
            try:
                os.kill(pid, signal.SIGTERM if attempt == 0 else signal.SIGKILL)
            except ProcessLookupError:
                pass
        time.sleep(.2)
    raise RuntimeError(f'private Ghostty host survived cleanup: {matches}')


def measure(mode, directory, setup):
    directory.mkdir(mode=0o700)
    app, library, config, options = setup
    runtime = runtime_program(mode, getattr(options, 'cpp_runtime', None))
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('TELAR_', 'BENCH_')) and k != 'DYLD_INSERT_LIBRARIES'}
    env.update(TELAR_SOCKET=str(directory / 'runtime.sock'),
               TELAR_SOCKET_PATH=str(directory / 'runtime.sock'),
               TELAR_HISTORY=str(directory / 'history.db'),
               TELAR_PROFILE_DIR=str(directory),
               XDG_DATA_HOME=str(directory / 'data'),
               XDG_CONFIG_HOME=str(directory / 'config'))
    if mode in TELAR_MODES:
        env['PATH'] = str(runtime.parent) + os.pathsep + env.get('PATH', '')
    case = getattr(options, 'case', None)
    if case:
        env.update(BENCH_BACKGROUND='flood' if case.endswith('-load') else 'idle',
                   BENCH_THROUGHPUT='1' if getattr(options, 'throughput', False) else '0',
                   BENCH_TEXT_PATTERN=getattr(options, 'text_pattern', 'repeat'))
        rate = background_rate(getattr(options, 'background_mib_per_second', None)) if case.endswith('-load') else None
        if rate is not None:
            env['BENCH_BACKGROUND_MIB_PER_SECOND'] = str(rate)
        fixture = [shutil.which('python3'),
                   str(Path(__file__).with_name('terminal_bench_fixture.py').resolve()), str(directory)]
        if getattr(options, 'image_size', None):
            fixture[1] = str(Path(__file__).with_name('image_bench_fixture.py').resolve())
            fixture += ['--width', str(options.image_size[0]), '--height', str(options.image_size[1])]
            fixture += ['--pattern', getattr(options, 'image_pattern', 'opaque')]
            fixture += ['--transport', getattr(options, 'image_transport', 'shared-memory')]
    else:
        fixture = [shutil.which('python3'),
                   str(Path(__file__).with_name('gui_tui_marker.py').resolve()), str(directory / 'size.json')]
    if mode != 'ghostty':
        subprocess.run([str(runtime), 'server', '--background', '--no-config'],
                       env=env, cwd=directory, check=True)
    args = client_command(mode, getattr(options, 'cpp_gui', None), config, fixture)
    probe_env = dict(DYLD_INSERT_LIBRARIES=str(library),
                     TELAR_DISPLAY_RESULT=str(directory / 'result.json'),
                     TELAR_DISPLAY_SAMPLES=str(options.samples + WARMUP),
                     TELAR_DISPLAY_WARMUP=str(WARMUP),
                     TELAR_DISPLAY_IDLE_SECONDS=str(getattr(options, 'idle_seconds', 2)),
                     TELAR_DISPLAY_ENDPOINT=getattr(options, 'endpoint', 'gpu'),
                     TELAR_DISPLAY_MODE=mode)
    if case:
        probe_env.update(TELAR_DISPLAY_DIRECTORY=str(directory),
                         TELAR_DISPLAY_LAYOUT=case.removesuffix('-load'),
                         TELAR_DISPLAY_PANES=str(1 if case == 'single' else options.panes))
    if options.viewport and (mode in TELAR_MODES or case):
        probe_env['TELAR_DISPLAY_VIEWPORT'] = ','.join(map(str, options.viewport))
    if getattr(options, 'float_windows', False):
        probe_env['TELAR_DISPLAY_AEROSPACE'] = shutil.which('aerospace')
    if getattr(options, 'capture', False):
        probe_env['TELAR_DISPLAY_CAPTURE'] = str(directory / 'window.png')
    if mode in TELAR_MODES:
        command = args
        launch_env = dict(env, **probe_env)
    else:
        wrapper = directory / 'run.sh'
        exported = {key: value for key, value in env.items()
                    if key in ('TELAR_SOCKET', 'TELAR_SOCKET_PATH', 'TELAR_HISTORY', 'XDG_DATA_HOME', 'XDG_CONFIG_HOME')
                    or key.startswith('BENCH_')}
        wrapper.write_text('#!/bin/sh\nunset DYLD_INSERT_LIBRARIES TELAR_DISPLAY_RESULT\n'
                           'export ' + shlex.join([key + '=' + value for key, value in exported.items()])
                           + '\nexec ' + shlex.join(args) + '\n')
        wrapper.chmod(0o700)
        command = [str(app / 'Contents/MacOS/ghostty'),
                    '--config-default-files=false', '--font-family=JetBrains Mono',
                    '--font-size=15', '--window-padding-x=0', '--window-padding-y=0',
                    '--window-save-state=never', '--initial-window=true', '--shell-integration=none',
                    '--confirm-close-surface=false', '--quit-after-last-window-closed=true',
                    '--window-vsync=' + options.vsync,
                    '--keybind=ctrl+shift+d=new_split:right',
                    '--keybind=ctrl+shift+p=goto_split:previous',
                    '--keybind=ctrl+shift+t=new_tab',
                    '--keybind=ctrl+shift+o=goto_tab:1',
                    '--command=' + str(wrapper)]
        launch_env = dict(env, **probe_env)

    launch_env['TELAR_DISPLAY_EXECUTABLE'] = command[0]
    identity = None
    try:
        if mode in TELAR_MODES:
            identity = runtime_identity(directory / 'runtime.sock', runtime)
            (directory / 'runtime-identity.json').write_text(json.dumps(identity, indent=2) + '\n')
        with (directory / 'launch.log').open('w') as log:
            process = subprocess.Popen(command, env=launch_env, cwd=getattr(options, 'cwd', None) or directory, stdout=log, stderr=log)
            try:
                if mode in TELAR_MODES:
                    gui_identity = process_identity(process.pid)
                    if gui_identity['path'] != str(Path(command[0]).resolve()):
                        raise ValueError(f'Unexpected GUI executable: {gui_identity}')
                    (directory / 'gui-identity.json').write_text(json.dumps(gui_identity, indent=2) + '\n')
                process.wait(timeout=105)
            except BaseException:
                process.kill()
                process.wait()
                raise
            if process.returncode:
                raise RuntimeError(f'{mode} exited with {process.returncode}: {directory}')
    finally:
        if mode == 'ghostty':
            cleanup_host(app)
        if mode != 'ghostty':
            try:
                if getattr(options, 'image_size', None) and identity is not None:
                    finish_image_fixture(directory, identity['pid'])
            finally:
                shutdown = stop_runtime(str(runtime), env)
                (directory / 'shutdown.json').write_text(json.dumps(shutdown, indent=2) + '\n')
    result_path = directory / 'result.json'
    if not result_path.is_file():
        raise RuntimeError(f'{mode} exited without a probe result; inspect logs and receipts in {directory}')
    result = json.loads(result_path.read_text())
    if mode in TELAR_MODES:
        result['runtime_identity'] = identity
        result['gui_identity'] = gui_identity
    if result['failed'] or len(result['gpu_ms']) != options.samples + WARMUP:
        raise ProbeFailure(mode, result)
    endpoint = getattr(options, 'endpoint', 'gpu')
    if result.get('endpoint', 'gpu') != endpoint:
        raise ValueError('The native probe used a different frame endpoint')
    samples = latency_samples(result)
    if len(samples) != options.samples + WARMUP:
        raise ValueError('The native probe did not complete every requested frame endpoint')
    result.update(mode=mode, pty_cells=json.loads((directory / 'size.json').read_text()),
                  warmup=WARMUP, summary=summarize(samples[WARMUP:]))
    if getattr(options, 'capture', False):
        capture = directory / 'window.png'
        result['capture'] = dict(path=str(capture), sha256=hashlib.sha256(capture.read_bytes()).hexdigest())
    if case:
        result['case'] = case
        result['text_pattern'] = env['BENCH_TEXT_PATTERN']
        result['background_mib_per_second'] = rate
        result['fixtures'] = [json.loads(path.read_text()) for path in sorted((directory / 'receipts').glob('*.json'))]
        expected = 1 if case == 'single' else options.panes
        if len(result['fixtures']) != expected:
            raise RuntimeError(f'expected {expected} fixtures, got {result["fixtures"]}')
        if sum(f['role'] == 'primary' for f in result['fixtures']) != 1 or any(
                f['error'] or f['phase'] == 'failed' or min(f['rows'], f['cols']) <= 0
                or f.get('text_pattern') != env['BENCH_TEXT_PATTERN']
                or f.get('background_mib_per_second') != rate
                for f in result['fixtures']):
            raise RuntimeError(f'invalid fixture receipts: {result["fixtures"]}')
        throughput = directory / 'throughput.json'
        if getattr(options, 'throughput', False):
            result['throughput'] = json.loads(throughput.read_text())
            cases = result['throughput']['cases']
            if (result['throughput']['failed'] or [c['name'] for c in cases] != ['ascii', 'ansi']
                    or result['throughput'].get('text_pattern') != env['BENCH_TEXT_PATTERN']
                    or any(c['bytes'] != 8 * 1024 * 1024 or c['elapsed_ms'] <= 0
                           or c.get('text_pattern') != env['BENCH_TEXT_PATTERN']
                           or len(c.get('payload_sha256', '')) != 64 for c in cases)):
                raise RuntimeError(f'invalid throughput result: {result["throughput"]}')
        if rate is not None:
            result['background_load'] = background_load(result['fixtures'], rate)
        if getattr(options, 'image_size', None):
            result['image_size'] = list(options.image_size)
            result['image_pattern'] = getattr(options, 'image_pattern', 'opaque')
            result['image_transport'] = getattr(options, 'image_transport', 'shared-memory')
            validate_image_receipt(result, options.image_size)
    (directory / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    if mode in TELAR_MODES:
        validate_telar_display_sync(result)
    if case and rate is not None and not result['background_load']['rate_met']:
        raise RuntimeError(f'background output missed its requested rate; raw observations retained in {result_path}')
    print(json.dumps(dict(mode=mode, round=directory.name, viewport=result['viewport'],
                          pty_cells=result['pty_cells'], **result['summary'])), flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path, help='new short /tmp path for isolated sockets')
    parser.add_argument('--ghostty-app', type=Path, default=Path('/Applications/Ghostty.app'))
    parser.add_argument('--samples', type=int, default=100)
    parser.add_argument('--rounds', type=int, default=3)
    parser.add_argument('--idle-seconds', type=float, default=2, help='idle CPU observation before input samples, from 0 to 10 seconds')
    parser.add_argument('--vsync', choices=['true', 'false'], default='true', help='Ghostty presentation policy; Telar requires true')
    parser.add_argument('--endpoint', choices=['gpu', 'presented'], default='gpu', help='Measure verified GPU completion or the native drawable presentation timestamp')
    parser.add_argument('--mode', choices=['native', 'gui-cpp', 'ghostty'], default='native',
                        help='native compares Ghostty with the C++ GUI')
    parser.add_argument('--cpp-gui', type=Path, help='Qt Quick executable for --mode native or gui-cpp')
    parser.add_argument('--cpp-runtime', type=Path, help='explicit runtime for gui-cpp; stage the same binary as its telar helper')
    parser.add_argument('--config', type=Path, help='GUI configuration for the Telar client')
    parser.add_argument('--cwd', type=Path, help='initial working directory for --mode gui-cpp')
    parser.add_argument('--capture', action='store_true', help='save a Metal frame before warmup; peak RSS includes capture overhead')
    parser.add_argument('--cases', nargs='+', choices=['single', 'splits', 'tabs', 'splits-load', 'tabs-load'],
                        default=['single'])
    parser.add_argument('--panes', type=int, choices=[2, 4], default=4)
    parser.add_argument('--throughput', action='store_true', help='run 8 MiB ASCII/ANSI DSR probes before latency')
    parser.add_argument('--image-size', type=int, nargs=2, metavar=('WIDTH', 'HEIGHT'),
                        help='replace a Kitty RGBA image on each input; requires single-pane Telar modes')
    parser.add_argument('--image-pattern', choices=['opaque', 'alpha-edge', 'alpha-gradient'], default='opaque',
                        help='alpha patterns require --image-size 16 16 and use an opaque border with a center marker')
    parser.add_argument('--image-transport', choices=['shared-memory', 'inline'], default='shared-memory',
                        help='Kitty image input transport; inline base64 commands are prepared before timing')
    parser.add_argument('--text-pattern', choices=['repeat', 'variable'], default='repeat',
                        help='repeat the original 64-byte line or vary every line deterministically')
    parser.add_argument('--background-mib-per-second', type=background_rate,
                        help='limit each background fixture in load cases; omitted means unlimited')
    parser.add_argument('--float-windows', action='store_true', help='float only probe windows in AeroSpace before resizing')
    parser.add_argument('--source', type=Path, help='source checkout used for the measured binaries')
    parser.add_argument('--max-load', type=float, nargs=2, metavar=('ONE_MINUTE', 'FIVE_MINUTES'),
                        help='positive host load limits; defaults to max(2, CPUs/2) and max(3, CPUs*3/4); high load discards the whole series')
    parser.add_argument('--viewport', type=int, nargs=2, metavar=('WIDTH', 'HEIGHT'),
                        help='fix render-target pixels independently of the window manager')
    options = parser.parse_args()
    if options.max_load is not None and any(not math.isfinite(value) or value <= 0 for value in options.max_load):
        parser.error('--max-load requires two finite positive numbers')
    if not 0 <= options.idle_seconds <= 10:
        parser.error('--idle-seconds must be finite and between 0 and 10')
    if options.capture and options.idle_seconds == 0:
        parser.error('--capture requires a positive --idle-seconds interval')
    if options.config is not None and not options.config.is_file():
        parser.error('--config must name an existing Lua file')
    modes = MODE_GROUPS.get(options.mode, [options.mode])
    if options.vsync != 'true' and any(mode in TELAR_MODES for mode in modes):
        parser.error('Telar comparisons require --vsync true')
    if options.image_pattern != 'opaque' and not options.image_size:
        parser.error('--image-pattern requires --image-size')
    if options.image_transport != 'shared-memory' and not options.image_size:
        parser.error('--image-transport requires --image-size')
    if options.image_size:
        from image_bench_fixture import image_extent
        from image_patterns import placement
        try:
            image_extent(*options.image_size)
            placement(options.image_size, options.image_pattern)
        except ValueError as error:
            parser.error(str(error))
        if options.cases != ['single'] or options.throughput or any(mode not in TELAR_MODES for mode in modes):
            parser.error('--image-size requires --cases single, Telar-only modes and no --throughput')
    if options.endpoint == 'presented' and any(mode not in TELAR_MODES for mode in modes):
        parser.error('--endpoint presented requires Telar-only modes')
    if options.cwd is not None:
        if 'ghostty' in modes or not options.cwd.is_dir():
            parser.error('--cwd requires Telar-only modes and an existing directory')
        options.cwd = options.cwd.resolve()
    if 'gui-cpp' in modes:
        if options.cpp_gui is None or not options.cpp_gui.is_file() or not os.access(options.cpp_gui, os.X_OK):
            parser.error('--mode native and gui-cpp require an executable --cpp-gui')
        options.cpp_gui = options.cpp_gui.resolve()
        if options.cpp_runtime is None or not options.cpp_runtime.is_file() or not os.access(options.cpp_runtime, os.X_OK):
            parser.error('--mode native and gui-cpp require an executable --cpp-runtime')
        options.cpp_runtime = options.cpp_runtime.resolve()
        try:
            staged_runtime(options.cpp_gui, options.cpp_runtime)
        except ValueError as error:
            parser.error(str(error))
    if options.throughput and options.cases != ['single']:
        parser.error('--throughput requires --cases single; it runs before layout creation')
    if options.background_mib_per_second is not None and not any(case.endswith('-load') for case in options.cases):
        parser.error('--background-mib-per-second requires a load case')
    if options.float_windows and not shutil.which('aerospace'):
        parser.error('--float-windows requires the aerospace CLI')
    if options.viewport and any(v < 1 or v > 8192 for v in options.viewport):
        parser.error('viewport dimensions must be 1..8192')
    if not 1 <= options.samples <= 400 or not 1 <= options.rounds <= 10:
        parser.error('samples must be 1..400 and rounds 1..10')
    directory = options.directory.resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    host = HostLoadGate(directory / 'host-load.json', options.max_load)
    host.checkpoint('before-setup')
    app = directory / 'GhosttyProbe.app'
    if 'ghostty' in modes:
        shutil.copytree(options.ghostty_app, app, symlinks=True)
        info_path = app / 'Contents/Info.plist'
        with info_path.open('rb') as file:
            info = plistlib.load(file)
        info['CFBundleIdentifier'] = 'dev.telar.latency-probe.' + hashlib.sha256(str(directory).encode()).hexdigest()[:12]
        info['SUEnableAutomaticChecks'] = False
        with info_path.open('wb') as file:
            plistlib.dump(info, file)
        subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(app)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    library = directory / 'probe.dylib'
    subprocess.run(['clang', '-dynamiclib', '-O2', '-fobjc-arc', '-framework', 'AppKit',
                    '-framework', 'QuartzCore', '-framework', 'Metal',
                    str(Path(__file__).with_suffix('.m')), '-o', str(library)], check=True)
    if options.config is not None:
        config = options.config.resolve()
    else:
        config = directory / 'config.lua'
        config.write_text("local t = require('telar')\nreturn { api_version = 2, client = { "
                          "sidebar = { visible = false }, pane_gaps = false, "
                          "bars = { bottom = { left = t.bar.static(' '), center = t.bar.static(' '), "
                          "right = t.bar.tabs() } } }, gui = { font = { family = 'JetBrains Mono', size = 15 }, "
                          "window = { padding = { x = 0, y = 0 }, background_opacity = 1 }, "
                          "cursor = { blink = false } } }\n")
    manifest = dict(host_load_policy=host.policy,
                    vsync=options.vsync, endpoint=options.endpoint, warmup=WARMUP, rounds=options.rounds,
                    idle_seconds=options.idle_seconds,
                    readback_diagnostics='TGB_READBACK_DIAGNOSTICS' in os.environ,
                    capture=options.capture,
                    working_directory=str(options.cwd) if options.cwd else None,
                    input_method='key', cases=options.cases, panes=options.panes,
                    image_size=options.image_size,
                    image_pattern=options.image_pattern,
                    image_transport=options.image_transport,
                    text_pattern=options.text_pattern, background_mib_per_second=options.background_mib_per_second,
                    background_rate_tolerance=BACKGROUND_RATE_TOLERANCE,
                    viewport=options.viewport, command_line=os.sys.argv,
                    platform=subprocess.check_output(['sw_vers'], text=True),
                    cpu=subprocess.check_output(['sysctl', '-n', 'machdep.cpu.brand_string'], text=True).strip(),
                    memory_bytes=int(subprocess.check_output(['sysctl', '-n', 'hw.memsize'], text=True)),
                    power=subprocess.check_output(['pmset', '-g', 'batt'], text=True),
                    started_at=time.strftime('%Y-%m-%dT%H:%M:%S%z'))
    source = options.source.resolve() if options.source else Path(__file__).resolve().parent.parent
    manifest['source_commit'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=source, text=True).strip()
    patch = subprocess.check_output(['git', 'diff', '--', 'services', 'dlls', 'cmake'], cwd=source)
    (directory / 'source.patch').write_bytes(patch)
    manifest['source_patch_sha256'] = hashlib.sha256(patch).hexdigest()
    if 'ghostty' in modes:
        ghostty = options.ghostty_app / 'Contents/MacOS/ghostty'
        manifest['ghostty_version'] = subprocess.check_output([str(ghostty), '+version'], text=True)
        manifest['ghostty_sha256'] = hashlib.sha256(ghostty.read_bytes()).hexdigest()
    if 'gui-cpp' in modes:
        manifest['cpp_gui'] = str(options.cpp_gui)
        manifest['cpp_gui_sha256'] = hashlib.sha256(options.cpp_gui.read_bytes()).hexdigest()
        manifest['cpp_runtime'] = executable_identity(options.cpp_runtime)
        manifest['cpp_runtime_helper'] = staged_runtime(options.cpp_gui, options.cpp_runtime)
        changed = subprocess.check_output(['git', 'ls-files', '-m', '-o', '--exclude-standard', '-z', '--', 'services'], cwd=source)
        manifest['cpp_changed_source_sha256'] = {
            name: hashlib.sha256((source / name).read_bytes()).hexdigest()
            for name in changed.decode().split('\0') if name and (source / name).is_file()}
    manifest['config_sha256'] = hashlib.sha256(config.read_bytes()).hexdigest()
    manifest['config_path'] = str(config)
    shutil.copy2(config, directory / 'used-config.lua')
    manifest['probe_sha256'] = {name: hashlib.sha256((Path(__file__).parent / name).read_bytes()).hexdigest()
                                for name in ('gui_tui_latency.py', 'gui_tui_latency.m', 'gui_view.h', 'terminal_bench_fixture.py', 'image_bench_fixture.py', 'image_patterns.py', 'kitty_stream.py', 'terminal_bench_report.py', 'bench_stack.py', 'benchmark_host.py')}
    probe_source = directory / 'probe-source'
    probe_source.mkdir()
    for name in manifest['probe_sha256']:
        shutil.copy2(Path(__file__).parent / name, probe_source / name)
    (directory / 'processes-before.txt').write_text(subprocess.check_output(['ps', '-axo', 'pid,ppid,%cpu,rss,comm'], text=True))
    (directory / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    results = []
    rejected = []
    setup = app, library, config, options
    host.checkpoint('before-series')
    for round_index in range(options.rounds):
        # Reversed cyclic permutations balance three variants over six rounds.
        offset = (round_index // 2) % len(modes)
        order = modes[offset:] + modes[:offset]
        if round_index % 2:
            order = order[::-1]
        for case in options.cases:
            options.case = case
            for mode in order:
                for attempt in range(3):
                    name = f'{round_index}-{case}-{mode}' + (f'-retry{attempt}' if attempt else '')
                    try:
                        with host.run(name):
                            result = measure(mode, directory / name, setup)
                        break
                    except ProbeFailure as failure:
                        row = failure.result
                        # A launch with no window and no inputs has no timing observations to discard.
                        if row['failed'] != 10 or row.get('panes_created') != 0 or row['gpu_ms'] or attempt == 2:
                            raise
                        rejected.append(dict(directory=name, reason='host opened no test window', result=row))
                        (directory / 'rejected.json').write_text(json.dumps(rejected, indent=2) + '\n')
                        print(f'retrying startup with no window: {name}', flush=True)
                result['round'] = round_index
                results.append(result)
                (directory / 'runs.json').write_text(json.dumps(results, indent=2) + '\n')
    host.finish()
    report = dict(manifest=manifest, runs=results, rejected_startups=rejected,
                  aggregate=aggregate_runs(results, options.cases, modes))
    (directory / 'comparison.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report['aggregate'], indent=2), flush=True)


if __name__ == '__main__':
    try:
        main()
    except HostLoadRejected as error:
        print(str(error), file=os.sys.stderr)
        raise SystemExit(2) from error
