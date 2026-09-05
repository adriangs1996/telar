#!/usr/bin/env python3
"""Paired local latency and shutdown measurements with isolated runtimes."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import time
from types import SimpleNamespace

import echo_latency
import graphics_roundtrip
import load_latency


def runtime_pids(socket):
    rows = subprocess.check_output(['ps', '-axo', 'pid,command'], text=True)
    return [int(row.split(None, 1)[0]) for row in rows.splitlines()[1:]
            if ' server --daemonized ' in row and f'--socket {socket} ' in row]


def process_table():
    rows = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,lstart=,command='], text=True)
    table = {}
    for row in rows.splitlines():
        fields = row.split(None, 7)
        if len(fields) == 8:
            table[int(fields[0])] = (int(fields[1]), ' '.join(fields[2:7]), fields[7])
    return table


def descendants(roots):
    table = process_table()
    owned = set(roots)
    while True:
        children = {pid for pid, (parent, _, _) in table.items() if parent in owned}
        if children <= owned:
            return {pid: table[pid] for pid in owned if pid in table}
        owned |= children


def owned_sessions(owned):
    sessions = set()
    for pid in owned:
        try:
            sessions.add(os.getsid(pid))
        except ProcessLookupError:
            pass
    if sessions & {os.getsid(0), os.getsid(os.getppid())}:
        raise RuntimeError('isolated runtime shares the runner session')
    return sessions


def session_members(sessions):
    members = []
    for pid in process_table():
        try:
            if os.getsid(pid) in sessions:
                members.append(pid)
        except ProcessLookupError:
            pass
    return members


def stop_runtime(binary, env):
    pids = runtime_pids(env['TELAR_SOCKET_PATH'])
    sessions = owned_sessions(descendants(pids))
    started = time.perf_counter()
    try:
        command = subprocess.run([binary, 'server', 'stop'], env=env,
                                 capture_output=True, timeout=5)
        reply = command.stdout.decode(errors='replace')
        code = command.returncode
    except subprocess.TimeoutExpired:
        reply, code = 'stop command timed out', -1
    deadline = started + 5
    while time.perf_counter() < deadline and runtime_pids(env['TELAR_SOCKET_PATH']):
        time.sleep(.02)
    remaining = runtime_pids(env['TELAR_SOCKET_PATH'])
    result = dict(elapsed_ms=(time.perf_counter() - started) * 1000,
                  exited=not remaining, returncode=code, reply=reply, pids=pids)
    # Session membership survives exec, reparenting and foreground-job changes.
    survivors = session_members(sessions)
    result['children_exited'] = not [pid for pid in survivors if pid not in pids]
    result['socket_removed'] = not Path(env['TELAR_SOCKET_PATH']).exists()
    for pid in survivors:
        if pid in (os.getpid(), os.getppid()):
            raise RuntimeError('refusing to signal the runner or its parent')
        try:
            if os.getsid(pid) in sessions:
                os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    cleanup_deadline = time.perf_counter() + 2
    while session_members(sessions) and time.perf_counter() < cleanup_deadline:
        time.sleep(.05)
    result['cleanup_complete'] = not session_members(sessions)
    if not result['cleanup_complete']:
        raise RuntimeError(f'isolated processes survived cleanup: {session_members(sessions)}')
    return result


def runtime_input_bytes(directory):
    paths = list(directory.glob('*.runtime-*.log'))
    if not paths:
        return 0
    rows = [json.loads(line) for line in paths[0].read_text().splitlines()
            if line.startswith('{') and line.endswith('}')]
    return rows[-1]['input_bytes'] if rows else 0


def slow_host(binary, directory, env):
    master, slave = load_latency.pty.openpty()
    load_latency.set_winsize(slave, 70, 240)
    proc = subprocess.Popen([binary, '--no-config'], stdin=slave, stdout=slave,
                            stderr=slave, env=env,
                            preexec_fn=load_latency.become_session_leader,
                            close_fds=True)
    os.close(slave)
    try:
        load_latency.drain(master, 3)
        load_latency.open_telar_floods(master, 2)
        load_latency.drain(master, 2)
        # Do not drain the host while the panes continue producing frames.
        time.sleep(3)
        before = runtime_input_bytes(directory)
        os.write(master, b'k' * 32)
        time.sleep(1.5)
        during = runtime_input_bytes(directory)
        load_latency.drain(master, 1.5)
        after = runtime_input_bytes(directory)
        return dict(input_sent=32, input_while_host_blocked=during - before,
                    input_after_drain=after - before)
    finally:
        load_latency.terminate(proc)
        os.close(master)


def measure(binary, directory, case, samples):
    directory.mkdir(mode=0o700, parents=True)
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('TELAR_', 'TMUX', 'HERDR'))}
    for name in ('data', 'config', 'cache'):
        (directory / name).mkdir(mode=0o700)
    env.update(TERM='xterm-256color', SHELL='/bin/sh', PS1='$ ',
               XDG_DATA_HOME=str(directory / 'data'),
               XDG_CONFIG_HOME=str(directory / 'config'),
               XDG_CACHE_HOME=str(directory / 'cache'),
               TELAR_SOCKET_PATH=str(directory / 'runtime.sock'))
    previous = os.getcwd()
    os.chdir(directory)
    try:
        if case == 'slow-host':
            return slow_host(binary, directory, env)
        if case == 'graphics':
            return graphics_roundtrip.measure(binary, directory, env)
        if case == 'echo':
            shell = directory / 'catshell'
            shell.write_text('#!/bin/sh\nexec /bin/cat\n')
            shell.chmod(0o700)
            env['SHELL'] = str(shell)
            values, timeouts = echo_latency.measure(
                [binary, '--no-config'], env, samples, .05, 40, 160, 3,
                echo_latency.SINGLE)
        else:
            args = SimpleNamespace(cmd=[binary, '--no-config'], rows=70,
                                   cols=240, warmup=3, mux='telar', floods=2,
                                   dump_screen=False, samples=samples, gap=.05)
            values, timeouts = load_latency.measure(args, env)
        return dict(raw_us=values, timeouts=timeouts,
                    **{name: echo_latency.percentile(values, p)
                       for name, p in [('p50_us', .5), ('p95_us', .95), ('p99_us', .99)]})
    finally:
        result = stop_runtime(binary, env)
        (directory / 'shutdown.json').write_text(json.dumps(result, indent=2))
        os.chdir(previous)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', required=True)
    parser.add_argument('--candidate', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--samples', type=int, default=200)
    parser.add_argument('--repetitions', type=int, default=5)
    parser.add_argument('--cases', nargs='+', default=['echo', 'load'])
    args = parser.parse_args()
    output = args.output.resolve()
    results = []
    binaries = dict(baseline=str(Path(args.baseline).resolve()),
                    candidate=str(Path(args.candidate).resolve()))
    for run in range(args.repetitions):
        for case in args.cases:
            order = ['baseline', 'candidate'] if run % 2 == 0 else ['candidate', 'baseline']
            for version in order:
                directory = output / f'{version}-{case}-{run}'
                result = measure(binaries[version], directory, case, args.samples)
                result.update(version=version, case=case, run=run,
                              shutdown=json.loads((directory / 'shutdown.json').read_text()))
                results.append(result)
                (output / 'results.json').write_text(json.dumps(results, indent=2))
                print(json.dumps({k: v for k, v in result.items() if k != 'raw_us'}), flush=True)


if __name__ == '__main__':
    main()
