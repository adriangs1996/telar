#!/usr/bin/env python3
"""Check runtime live-follow through an isolated PTY and the real wire codec.

Build services/runtime-cpp/tests/viewport_follow_probe.cpp with
build_runtime_scroll_probe.py, adding --include-dir services/gui-cpp. Supply
the resulting probe and one frozen runtime. For Zig, also pass --zig-wire
from build_viewport_follow_wire.py using that runtime's source revision.
This checks cells and protocol behavior only; it does not measure GUI latency or presentation.

Each scenario uses a fresh runtime. Reports retain semantic failures, and the
command exits nonzero if any scenario fails. Generated output must stay outside
versioned source. Runtime identity verification currently requires macOS.
"""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from bench_stack import executable_identity, runtime_identity
from benchmark_host import HostLoadGate
from perf_e2e import short_socket_path, stop_runtime


SCENARIOS = ('return', 'held', 'history', 'clamp', 'reflow', 'reflow-continuation', 'clear')


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def environment(directory):
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(('TELAR_', 'BENCH_', 'XDG_', 'TMUX', 'HERDR'))
           and key != 'DYLD_INSERT_LIBRARIES'}
    socket = str(short_socket_path(directory))
    env.update(TELAR_SOCKET=socket, TELAR_SOCKET_PATH=socket,
               TELAR_HISTORY=str(directory / 'history.db'),
               TELAR_PROFILE_DIR=str(directory),
               XDG_DATA_HOME=str(directory / 'data'),
               XDG_CONFIG_HOME=str(directory / 'config'),
               XDG_CACHE_HOME=str(directory / 'cache'))
    return env


def run_case(runtime, driver, directory, mode):
    directory.mkdir(mode=0o700)
    env = environment(directory)
    row = dict(mode=mode, valid=False, matches_expected=False)
    started = False
    try:
        with (directory / 'startup.log').open('w') as log:
            started = True
            subprocess.run([str(runtime), 'server', '--background', '--no-config'],
                           cwd=directory, env=env, stdout=log, stderr=log,
                           check=True, timeout=20)
        row['runtime_identity'] = runtime_identity(env['TELAR_SOCKET_PATH'], runtime)
        command = [*driver, env['TELAR_SOCKET_PATH'],
                   str(directory / 'child.json'), mode]
        row['command'] = command
        with (directory / 'stdout.log').open('w') as stdout, \
                (directory / 'stderr.log').open('w') as stderr:
            result = subprocess.run(command, cwd=directory, env=env,
                                    stdout=stdout, stderr=stderr, timeout=40)
        row['returncode'] = result.returncode
        if result.returncode == 0:
            result = json.loads((directory / 'stdout.log').read_text())
            row['result'] = result
            child = json.loads((directory / 'child.json').read_text())
            row['child'] = child
            row['valid'] = (result['mode'] == mode and result['cells_verified']
                            and result['child_exited'] and child['pid'] > 0
                            and child['initial_lines'] == 100
                            and child['additional_lines'] == 25)
            row['matches_expected'] = row['valid'] and result['matches_expected']
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        row['error'] = f'{type(error).__name__}: {error}'
    finally:
        if started:
            row['cleanup'] = stop_runtime(str(runtime), env)
            cleanup = row['cleanup']
            if not all(cleanup[key] for key in
                       ('exited', 'children_exited', 'socket_removed', 'cleanup_complete')):
                row['valid'] = row['matches_expected'] = False
            save(directory / 'shutdown.json', cleanup)
        save(directory / 'result.json', row)
    return row


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--probe', type=Path, required=True)
    parser.add_argument('--zig-wire', type=Path, help='Exact-reference adapter from build_viewport_follow_wire.py')
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    runtime = args.runtime.resolve(strict=True)
    probe = args.probe.resolve(strict=True)
    wire = None if args.zig_wire is None else args.zig_wire.resolve(strict=True)
    client = Path(__file__).with_name('viewport_follow_zig.py')
    command = [str(probe)] if wire is None else [sys.executable, str(client), '--wire', str(wire), '--fixture', str(probe)]
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    save(output / 'manifest.json', dict(
        scope='PTY/wire/cell correctness only; no timing or presentation claim.',
        runtime=executable_identity(runtime), probe=executable_identity(probe),
        controller=executable_identity(Path(__file__)), scenarios=SCENARIOS,
        zig_wire=None if wire is None else executable_identity(wire),
        zig_client=None if wire is None else executable_identity(client),
        uptime=subprocess.check_output(['uptime'], text=True)))
    host = HostLoadGate(output / 'host-load.json')
    host.checkpoint('before-series')
    rows = []
    for mode in SCENARIOS:
        with host.run(mode):
            row = run_case(runtime, command, output / mode, mode)
        rows.append(row)
        save(output / 'runs.json', rows)
        print(json.dumps(row), flush=True)
    host.finish()
    return 0 if all(row['matches_expected'] for row in rows) else 1


if __name__ == '__main__':
    raise SystemExit(main())
