#!/usr/bin/env python3
"""Compare Ghostty, Telar GUI and Telar TUI at verified GPU completion.

Resigns a private copy of Ghostty; never modifies the installed application.
The probe reads back one marker pixel within the rendering command buffer.
Metal and Metal 4 instrumentation have different overheads.
The optional GUI text endpoint starts at committed text instead of keyDown.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import signal
import statistics
import subprocess
import time

from echo_latency import percentile
from perf_e2e import stop_runtime

WARMUP = 20


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
    binary, app, library, config, options = setup
    env = {k: v for k, v in os.environ.items()
           if not k.startswith('TELAR_') and k != 'DYLD_INSERT_LIBRARIES'}
    env.update(TELAR_SOCKET=str(directory / 'runtime.sock'),
               TELAR_SOCKET_PATH=str(directory / 'runtime.sock'),
               TELAR_HISTORY=str(directory / 'history.db'),
               XDG_DATA_HOME=str(directory / 'data'),
               XDG_CONFIG_HOME=str(directory / 'config'))
    case = getattr(options, 'case', None)
    if case:
        env.update(BENCH_BACKGROUND='flood' if case.endswith('-load') else 'idle',
                   BENCH_THROUGHPUT='1' if getattr(options, 'throughput', False) else '0')
        fixture = [shutil.which('python3'),
                   str(Path(__file__).with_name('terminal_bench_fixture.py').resolve()), str(directory)]
    else:
        fixture = [shutil.which('python3'),
                   str(Path(__file__).with_name('gui_tui_marker.py').resolve()), str(directory / 'size.json')]
    if mode != 'ghostty':
        subprocess.run([str(binary), 'server', '--background', '--no-config'],
                       env=env, cwd=directory, check=True)
    args = [str(binary)] + (['gui'] if mode == 'gui' else [])
    args += ['--config', str(config)] + fixture
    if mode == 'ghostty':
        args = fixture
    probe_env = dict(DYLD_INSERT_LIBRARIES=str(library),
                     TELAR_DISPLAY_RESULT=str(directory / 'result.json'),
                     TELAR_DISPLAY_SAMPLES=str(options.samples + WARMUP),
                     TELAR_DISPLAY_INPUT_METHOD=options.input_method,
                     TELAR_DISPLAY_MODE=mode)
    if case:
        probe_env.update(TELAR_DISPLAY_DIRECTORY=str(directory),
                         TELAR_DISPLAY_LAYOUT=case.removesuffix('-load'),
                         TELAR_DISPLAY_PANES=str(1 if case == 'single' else options.panes))
    if options.viewport and (mode == 'gui' or case):
        probe_env['TELAR_DISPLAY_VIEWPORT'] = ','.join(map(str, options.viewport))
    if getattr(options, 'float_windows', False):
        probe_env['TELAR_DISPLAY_AEROSPACE'] = shutil.which('aerospace')
    if mode == 'gui':
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
    try:
        with (directory / 'launch.log').open('w') as log:
            process = subprocess.Popen(command, env=launch_env, cwd=directory, stdout=log, stderr=log)
            try:
                process.wait(timeout=105)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
                raise
            if process.returncode:
                raise RuntimeError(f'{mode} exited with {process.returncode}: {directory}')
    finally:
        if mode != 'gui':
            cleanup_host(app)
        if mode != 'ghostty':
            shutdown = stop_runtime(str(binary), env)
            (directory / 'shutdown.json').write_text(json.dumps(shutdown, indent=2) + '\n')
    result_path = directory / 'result.json'
    if not result_path.is_file():
        raise RuntimeError(f'{mode} exited without a probe result; inspect logs and receipts in {directory}')
    result = json.loads(result_path.read_text())
    if result['failed'] or len(result['gpu_ms']) != options.samples + WARMUP:
        raise ProbeFailure(mode, result)
    result.update(mode=mode, pty_cells=json.loads((directory / 'size.json').read_text()),
                  warmup=WARMUP, summary=summarize(result['gpu_ms'][WARMUP:]))
    if case:
        result['case'] = case
        result['fixtures'] = [json.loads(path.read_text()) for path in sorted((directory / 'receipts').glob('*.json'))]
        expected = 1 if case == 'single' else options.panes
        if len(result['fixtures']) != expected:
            raise RuntimeError(f'expected {expected} fixtures, got {result["fixtures"]}')
        if sum(f['role'] == 'primary' for f in result['fixtures']) != 1 or any(
                f['error'] or f['phase'] == 'failed' or min(f['rows'], f['cols']) <= 0
                for f in result['fixtures']):
            raise RuntimeError(f'invalid fixture receipts: {result["fixtures"]}')
        throughput = directory / 'throughput.json'
        if getattr(options, 'throughput', False):
            result['throughput'] = json.loads(throughput.read_text())
            cases = result['throughput']['cases']
            if (result['throughput']['failed'] or [c['name'] for c in cases] != ['ascii', 'ansi']
                    or any(c['bytes'] != 8 * 1024 * 1024 or c['elapsed_ms'] <= 0 for c in cases)):
                raise RuntimeError(f'invalid throughput result: {result["throughput"]}')
    (directory / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(dict(mode=mode, round=directory.name, viewport=result['viewport'],
                          pty_cells=result['pty_cells'], **result['summary'])), flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('directory', type=Path, help='new short /tmp path for isolated sockets')
    parser.add_argument('--ghostty-app', type=Path, default=Path('/Applications/Ghostty.app'))
    parser.add_argument('--samples', type=int, default=100)
    parser.add_argument('--rounds', type=int, default=3)
    parser.add_argument('--vsync', choices=['true', 'false'], default='true')
    parser.add_argument('--mode', choices=['both', 'all', 'native', 'gui', 'tui', 'ghostty'], default='both')
    parser.add_argument('--cases', nargs='+', choices=['single', 'splits', 'tabs', 'splits-load', 'tabs-load'],
                        default=['single'])
    parser.add_argument('--panes', type=int, choices=[2, 4], default=4)
    parser.add_argument('--throughput', action='store_true', help='run 8 MiB ASCII/ANSI DSR probes before latency')
    parser.add_argument('--float-windows', action='store_true', help='float only probe windows in AeroSpace before resizing')
    parser.add_argument('--source', type=Path, help='source checkout used for the measured binary')
    parser.add_argument('--input-method', choices=['key', 'text'], default='key',
                        help='keyDown event, or GUI committed text bypassing synthetic IME dispatch')
    parser.add_argument('--viewport', type=int, nargs=2, metavar=('WIDTH', 'HEIGHT'),
                        help='fix render-target pixels independently of the window manager')
    options = parser.parse_args()
    if options.input_method == 'text' and options.mode != 'gui':
        parser.error('--input-method text requires --mode gui')
    if options.throughput and options.cases != ['single']:
        parser.error('--throughput requires --cases single; it runs before layout creation')
    if options.float_windows and not shutil.which('aerospace'):
        parser.error('--float-windows requires the aerospace CLI')
    if options.viewport and any(v < 1 or v > 8192 for v in options.viewport):
        parser.error('viewport dimensions must be 1..8192')
    if not 1 <= options.samples <= 400 or not 1 <= options.rounds <= 10:
        parser.error('samples must be 1..400 and rounds 1..10')
    directory = options.directory.resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    binary = options.binary.resolve()
    app = directory / 'GhosttyProbe.app'
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
    config = directory / 'config.lua'
    config.write_text("local t = require('telar')\nreturn { api_version = 2, client = { "
                      "sidebar = { visible = false, renderer = 'cells' }, pane_gaps = false, "
                      "bars = { bottom = { left = t.bar.static(' '), center = t.bar.static(' '), "
                      "right = t.bar.tabs() } } }, gui = { font = { family = 'JetBrains Mono', size = 15 }, "
                      "window = { padding = { x = 0, y = 0 }, background_opacity = 1 }, "
                      "cursor = { blink = false } } }\n")
    manifest = dict(binary=str(binary), sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                    ghostty_version=subprocess.check_output(
                        [str(options.ghostty_app / 'Contents/MacOS/ghostty'), '+version'], text=True),
                    vsync=options.vsync, warmup=WARMUP, rounds=options.rounds,
                    input_method=options.input_method, cases=options.cases, panes=options.panes,
                    viewport=options.viewport, command_line=os.sys.argv,
                    platform=subprocess.check_output(['sw_vers'], text=True),
                    cpu=subprocess.check_output(['sysctl', '-n', 'machdep.cpu.brand_string'], text=True).strip(),
                    memory_bytes=int(subprocess.check_output(['sysctl', '-n', 'hw.memsize'], text=True)),
                    power=subprocess.check_output(['pmset', '-g', 'batt'], text=True),
                    started_at=time.strftime('%Y-%m-%dT%H:%M:%S%z'))
    source = options.source.resolve() if options.source else Path(__file__).resolve().parent.parent
    manifest['source_commit'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=source, text=True).strip()
    patch = subprocess.check_output(['git', 'diff', '--', 'src', 'build', 'build.zig', 'build.zig.zon'], cwd=source)
    (directory / 'source.patch').write_bytes(patch)
    manifest['source_patch_sha256'] = hashlib.sha256(patch).hexdigest()
    manifest['ghostty_sha256'] = hashlib.sha256((options.ghostty_app / 'Contents/MacOS/ghostty').read_bytes()).hexdigest()
    manifest['config_sha256'] = hashlib.sha256(config.read_bytes()).hexdigest()
    manifest['probe_sha256'] = {name: hashlib.sha256((Path(__file__).parent / name).read_bytes()).hexdigest()
                                for name in ('gui_tui_latency.py', 'gui_tui_latency.m', 'terminal_bench_fixture.py')}
    (directory / 'processes-before.txt').write_text(subprocess.check_output(['ps', '-axo', 'pid,ppid,%cpu,rss,comm'], text=True))
    (directory / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    results = []
    rejected = []
    setup = binary, app, library, config, options
    modes = dict(both=['gui', 'tui'], all=['ghostty', 'gui', 'tui'], native=['ghostty', 'gui']).get(options.mode, [options.mode])
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
    report = dict(manifest=manifest, runs=results, rejected_startups=rejected, aggregate={
        f'{case}/{mode}': summarize([value for result in results if result['mode'] == mode and result['case'] == case
                         for value in result['gpu_ms'][WARMUP:]])
        for case in options.cases for mode in modes})
    (directory / 'comparison.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report['aggregate'], indent=2), flush=True)


if __name__ == '__main__':
    main()
