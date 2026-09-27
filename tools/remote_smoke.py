#!/usr/bin/env python3
"""Verify SSH detach/reconnect on a fresh Linux runtime without typing into unknown panes.

The headless client attaches with `--remote`. It shows nothing while it
runs, so a reconnect first detaches and reads the client's exit dump to
confirm the pane is this run's before a later attach types into it."""
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / 'tools'))
import headless_client

DEST = ''
BINARY = str(ROOT / 'zig-out/bin/telar-headless')
TOKEN = uuid.uuid4().hex
WORK = Path(tempfile.mkdtemp(prefix='telar-remote-smoke-'))


def ssh(command):
    return subprocess.check_output(['ssh', '-T', '-oBatchMode=yes', '--', DEST, command],
                                   text=True, timeout=15).strip()


def launch(arguments, name):
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(('TELAR_', 'TMUX', 'HERDR'))}
    env['TERM'] = 'xterm-256color'
    # A deliberately local-only SHELL must not become the remote default.
    env['SHELL'] = '/does/not/exist/on/linux'
    client = headless_client.HeadlessClient(
        ['--no-config', '--remote', DEST, *arguments], env=env, cwd=WORK, size=(160, 40),
        dump=WORK / f'{name}-dump.json', log=WORK / f'{name}.log', binary=BINARY,
    )
    client.wait_ready()
    return client


def detach(client):
    client.key('ctrl+b')
    client.text('d')
    status = client.process.wait(timeout=10)
    client.close_log()
    if status:
        raise RuntimeError(f'Client exited with {status}')


def shows_ready(client):
    return any(f'READY_{TOKEN}' in line for pane in client.dump()['panes'] for line in pane['lines'])


def main():
    global DEST, BINARY
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', required=True, help='SSH host or configured alias')
    parser.add_argument('--binary', default=BINARY, help='Local telar-headless binary, beside telar')
    parser.add_argument('--output', type=Path, default=ROOT / '.zig-out/remote-smoke/result.json')
    options = parser.parse_args()
    DEST = options.destination
    BINARY = str(Path(options.binary).resolve())
    options.output.parent.mkdir(parents=True, exist_ok=True)
    directory = ssh('mktemp -d /tmp/telar-remote-smoke.XXXXXX')
    quoted = shlex.quote(directory)
    script = (
        f'export TELAR_REMOTE_SMOKE_TOKEN={TOKEN}; '
        f'printf "%s\\n" "$$" > {quoted}/pid; '
        f'uname -s > {quoted}/system; pwd > {quoted}/cwd; '
        f'printf "READY_%s\\n" "{TOKEN}"; exec /bin/bash --noprofile --norc'
    )
    client = launch(['/bin/bash', '-c', script], 'first')
    try:
        time.sleep(5)
        first_pid = ssh(f'cat {quoted}/pid')
        system = ssh(f'cat {quoted}/system')
        cwd = ssh(f'cat {quoted}/cwd')
        if system != 'Linux' or cwd != ssh('printf "%s" "$HOME"'):
            raise RuntimeError(f'Unexpected remote launch: {system}, {cwd}')
        detach(client)
        if not shows_ready(client):
            raise RuntimeError(f'No owned shell appeared; check {WORK} for a failed connection or existing workspace')
        ssh(f'kill -0 {first_pid}')
    finally:
        client.terminate()

    # Reconnect and leave again without typing, to see which pane it is.
    client = launch([], 'check')
    try:
        time.sleep(4)
        detach(client)
        if not shows_ready(client):
            raise RuntimeError('Reconnected to an unknown pane; refusing to type into it')
    finally:
        client.terminate()

    client = launch([], 'reconnected')
    try:
        time.sleep(2)
        client.text(f'test "$TELAR_REMOTE_SMOKE_TOKEN" = {TOKEN} && printf "%s\\n" "$$" > {quoted}/reconnected')
        client.key('enter')
        time.sleep(2)
        second_pid = ssh(f'cat {quoted}/reconnected')
        if first_pid != second_pid:
            raise RuntimeError('Reconnection did not retain the original Linux process')
        detach(client)
    finally:
        client.terminate()

    result = dict(client_system=os.uname().sysname, server_system=system,
                  client_uid=os.getuid(), server_uid=int(ssh('id -u')),
                  destination=DEST, remote_cwd=cwd, pane_pid=first_pid,
                  reconnected_pid=second_pid, survives_detach=True,
                  shell_state_preserved=True, result_directory=directory)
    report = json.dumps(result, indent=2) + '\n'
    options.output.write_text(report)
    print(report, end='')


if __name__ == '__main__':
    main()
