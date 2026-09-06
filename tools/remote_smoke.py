#!/usr/bin/env python3
"""Verify SSH detach/reconnect on a fresh Linux runtime without typing into unknown panes."""
import argparse
import json
import os
from pathlib import Path
import pty
import shlex
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / 'tools'))
import echo_latency as terminal

DEST = ''
BINARY = str(ROOT / 'zig-out/bin/telar')
TOKEN = uuid.uuid4().hex


def ssh(command):
    return subprocess.check_output(['ssh', '-T', '-oBatchMode=yes', '--', DEST, command],
                                   text=True, timeout=15).strip()


def launch(arguments):
    master, slave = pty.openpty()
    terminal.set_winsize(slave, 40, 160)
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(('TELAR_', 'TMUX', 'HERDR'))}
    env['TERM'] = 'xterm-256color'
    # A deliberately local-only SHELL must not become the remote default.
    env['SHELL'] = '/does/not/exist/on/linux'
    process = subprocess.Popen(
        [BINARY, '--no-config', '--remote', DEST, *arguments],
        stdin=slave, stdout=slave, stderr=slave, env=env,
        preexec_fn=terminal.become_session_leader, close_fds=True,
    )
    os.close(slave)
    return process, master


def detach(process, master):
    os.write(master, b'\x02d')
    terminal.drain(master, 1)
    process.wait(timeout=5)
    if process.returncode:
        raise RuntimeError(f'Client exited with {process.returncode}')


def main():
    global DEST, BINARY
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', required=True, help='SSH host or configured alias')
    parser.add_argument('--binary', default=BINARY, help='Local Telar binary')
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
    process, master = launch(['/bin/bash', '-c', script])
    try:
        banner = terminal.drain(master, 5)
        if f'READY_{TOKEN}'.encode() not in terminal.visible(banner):
            screen_log = options.output.with_suffix('.screen.log')
            screen_log.write_bytes(banner)
            raise RuntimeError(f'No owned shell appeared; check {screen_log} for a failed connection or existing workspace')
        first_pid = ssh(f'cat {quoted}/pid')
        system = ssh(f'cat {quoted}/system')
        cwd = ssh(f'cat {quoted}/cwd')
        if system != 'Linux' or cwd != ssh('printf "%s" "$HOME"'):
            raise RuntimeError(f'Unexpected remote launch: {system}, {cwd}')
        detach(process, master)
        ssh(f'kill -0 {first_pid}')
    finally:
        if process.poll() is None:
            terminal.terminate(process)
        if master is not None:
            os.close(master)

    process, master = launch([])
    try:
        banner = terminal.drain(master, 4)
        if f'READY_{TOKEN}'.encode() not in terminal.visible(banner):
            raise RuntimeError('Reconnected to an unknown pane; refusing to type into it')
        command = (
            f'test "$TELAR_REMOTE_SMOKE_TOKEN" = {TOKEN} && '
            f'printf "%s\\n" "$$" > {quoted}/reconnected\r'
        )
        os.write(master, command.encode())
        terminal.drain(master, 2)
        second_pid = ssh(f'cat {quoted}/reconnected')
        if first_pid != second_pid:
            raise RuntimeError('Reconnection did not retain the original Linux process')
        detach(process, master)
    finally:
        if process.poll() is None:
            terminal.terminate(process)
        if master is not None:
            os.close(master)

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
