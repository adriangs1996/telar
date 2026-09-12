#!/usr/bin/env python3
"""Compare Telar GUI with Telar TUI inside Ghostty at verified GPU completion.

Resigns a private copy of Ghostty; never modifies the installed application.
The probe copies one marker pixel into 256 bytes within the rendering command
buffer. This adds the same readback operation to both measured paths.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import statistics
import subprocess

from echo_latency import percentile

WARMUP = 20


def summarize(values):
    return dict(n=len(values), p50_ms=statistics.median(values),
                p95_ms=percentile(values, .95), p99_ms=percentile(values, .99),
                max_ms=max(values))


def measure(mode, directory, setup):
    directory.mkdir(mode=0o700)
    binary, app, library, config, options = setup
    env = {k: v for k, v in os.environ.items()
           if not k.startswith('TELAR_') and k != 'DYLD_INSERT_LIBRARIES'}
    env.update(TELAR_SOCKET=str(directory / 'runtime.sock'),
               TELAR_HISTORY=str(directory / 'history.db'))
    subprocess.run([str(binary), 'server', '--background', '--no-config'], env=env, check=True)
    args = [str(binary)] + (['gui'] if mode == 'gui' else [])
    args += ['--config', str(config), shutil.which('python3'),
             str(Path(__file__).with_name('gui_tui_marker.py').resolve()),
             str(directory / 'size.json')]
    probe_env = dict(DYLD_INSERT_LIBRARIES=str(library),
                     TELAR_DISPLAY_RESULT=str(directory / 'result.json'),
                     TELAR_DISPLAY_SAMPLES=str(options.samples + WARMUP))
    if options.viewport and mode == 'gui':
        probe_env['TELAR_DISPLAY_VIEWPORT'] = ','.join(map(str, options.viewport))
    if mode == 'gui':
        command = args
        launch_env = dict(env, **probe_env)
    else:
        wrapper = directory / 'run.sh'
        wrapper.write_text('#!/bin/sh\nunset DYLD_INSERT_LIBRARIES TELAR_DISPLAY_RESULT\n'
                           'export ' + shlex.join(['TELAR_SOCKET=' + env['TELAR_SOCKET'],
                                                  'TELAR_HISTORY=' + env['TELAR_HISTORY']])
                           + '\nexec ' + shlex.join(args) + '\n')
        wrapper.chmod(0o700)
        command = ['open', '-n', '-W', '-a', str(app)]
        for key, value in probe_env.items():
            command += ['--env', key + '=' + value]
        command += ['--stdout', str(directory / 'host.log'),
                    '--stderr', str(directory / 'host.log'), '--args',
                    '--config-default-files=false', '--font-family=JetBrains Mono',
                    '--font-size=15', '--window-padding-x=0', '--window-padding-y=0',
                    '--window-save-state=never', '--shell-integration=none',
                    '--confirm-close-surface=false', '--quit-after-last-window-closed=true',
                    '--window-vsync=' + options.vsync, '-e', str(wrapper)]
        launch_env = env
    try:
        with (directory / 'launch.log').open('w') as log:
            process = subprocess.Popen(command, env=launch_env, stdout=log, stderr=log)
            try:
                process.wait(timeout=105)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
                raise
            if process.returncode:
                raise RuntimeError(f'{mode} exited with {process.returncode}: {directory}')
    finally:
        subprocess.run([str(binary), 'server', 'stop'], env=env,
                       stdout=subprocess.DEVNULL, timeout=10, check=False)
    result = json.loads((directory / 'result.json').read_text())
    if result['failed'] or len(result['gpu_ms']) != options.samples + WARMUP:
        raise RuntimeError(f'incomplete {mode} measurement: {result}')
    result.update(mode=mode, pty_cells=json.loads((directory / 'size.json').read_text()),
                  warmup=WARMUP, summary=summarize(result['gpu_ms'][WARMUP:]))
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
    parser.add_argument('--mode', choices=['both', 'gui', 'tui'], default='both')
    parser.add_argument('--viewport', type=int, nargs=2, metavar=('WIDTH', 'HEIGHT'),
                        help='fix GUI render-target pixels independently of the window manager')
    options = parser.parse_args()
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
    info['CFBundleIdentifier'] = 'dev.telar.latency-probe'
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
                      "right = t.bar.tabs() } } } }\n")
    manifest = dict(binary=str(binary), sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                    ghostty_version=subprocess.check_output(
                        [str(options.ghostty_app / 'Contents/MacOS/ghostty'), '+version'], text=True),
                    vsync=options.vsync, warmup=WARMUP, rounds=options.rounds)
    (directory / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    results = []
    setup = binary, app, library, config, options
    for round_index in range(options.rounds):
        modes = ['gui', 'tui'] if round_index % 2 == 0 else ['tui', 'gui']
        for mode in modes:
            if options.mode != 'both' and options.mode != mode:
                continue
            results.append(measure(mode, directory / f'{round_index}-{mode}', setup))
    report = dict(manifest=manifest, runs=results, aggregate={
        mode: summarize([value for result in results if result['mode'] == mode
                         for value in result['gpu_ms'][WARMUP:]])
        for mode in sorted({result['mode'] for result in results})})
    (directory / 'comparison.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report['aggregate'], indent=2), flush=True)


if __name__ == '__main__':
    main()
