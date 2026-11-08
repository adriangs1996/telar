#!/usr/bin/env python3
"""CLI wire-contract regression tests; no live user runtime required."""
import argparse
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import threading
import time


def integer(value, code='Q'):
    return struct.pack('<' + code, value)


def text(value, code='H'):
    value = value.encode() if isinstance(value, str) else value
    return integer(len(value), code) + value


def receive(connection):
    def exact(count):
        data = b''
        while len(data) < count:
            chunk = connection.recv(count - len(data))
            if not chunk:
                return None
            data += chunk
        return data
    prefix = exact(4)
    return exact(struct.unpack('<I', prefix)[0]) if prefix else None


def send(connection, frame):
    connection.sendall(integer(len(frame), 'I') + frame)


def agent(status, title='Fixture', generation=29, tree=0):
    return (integer(17) + integer(generation) + b'\0' + integer(3) + integer(5) + integer(1, 'H') + integer(123, 'I') + bytes(range(16))
            + text('Workspace') + text('Tab') + text(title) + b'\x02\x02' + text('/fixture') + b'\x01'
            + text('claude') + text('Claude') + text('') + b'\0' + bytes([status, 2 if status == 2 else 0]) + text('event')
            + integer(7, 'I') + b'\x03\x01\x64' + integer(1) + integer(1, 'q') + integer(2, 'q') + integer(tree)
            + text('Finished\nmessage') + integer(1, 'H') + integer(2, 'H') + text('Step'))


class Fixture:
    def __init__(self, root):
        self.path = root / 'runtime.sock'
        self.listener = socket.socket(socket.AF_UNIX)
        self.listener.bind(str(self.path))
        self.listener.listen()
        self.listener.settimeout(.05)
        self.stop = threading.Event()
        self.frames = []
        self.errors = []
        self.status = 3
        self.states = []
        self.title = 'Fixture'
        self.refusal = None
        self.route_status = 1
        self.topology = False
        self.texts = []
        self.trees = []
        self.tree = 0
        self.generation = 29
        self.bump_on_send = False
        self.ack_ignored = False
        self.duplicate = False
        self.workers = []
        self.thread = threading.Thread(target=self.accept)
        self.thread.start()

    def accept(self):
        while not self.stop.is_set():
            try:
                conn, _ = self.listener.accept()
            except TimeoutError:
                continue
            worker = threading.Thread(target=self.serve, args=(conn,))
            self.workers.append(worker)
            worker.start()

    def serve(self, connection):
        try:
            with connection:
                connection.settimeout(10)
                hello = receive(connection)
                if hello is None:
                    return
                assert hello[:9] == b'TELARIPC\x01'
                send(connection, b'TELARIPC\x02' + hello[9:])
                while (frame := receive(connection)) is not None:
                    self.frames.append((time.monotonic(), frame))
                    tag, request = frame[0], frame[1:9]
                    if self.refusal and tag == self.refusal[0]:
                        send(connection, b'\x84' + request + integer(self.refusal[1], 'H') + b'refused')
                    elif tag == 0x1c:
                        status = self.states.pop(0) if self.states else self.status
                        entry = agent(status, self.title, self.generation, self.tree)
                        send(connection, b'\x96' + integer(11) + integer(2 if self.duplicate else 1, 'H') + entry * (2 if self.duplicate else 1))
                    elif tag == 0x1d:
                        value = self.texts.pop(0) if self.texts else 'hello\n\b\f\x7f'
                        send(connection, b'\xa0' + request + frame[9:17] + b'\x01' + text(value, 'I') + b'\x01' + integer(7, 'i'))
                    elif tag == 0x21:
                        send(connection, b'\xa3' + request + frame[9:17] + b'\0' + integer(1, 'H') + integer(2, 'H') + integer(8, 'I') + integer(5, 'H'))
                    elif tag == 0x33:
                        send(connection, b'\xad' + request + b'\x01' + integer(41) + integer(43) + integer(47) + integer(1, 'H') + integer(17) + integer(1))
                    elif tag == 0x35:
                        reply = bytearray(frame)
                        reply[0], reply[26] = 0xaf, self.route_status
                        send(connection, reply)
                    elif tag == 0x27:
                        send(connection, b'\xa8' + request + b'\0' + integer(19))
                    elif tag == 0x14:
                        entry = integer(3) + text('Workspace') + text('/fixture') + integer(1, 'H') + text('') + b'\0'
                        trees = b''.join(integer(identity) + integer(3) + b'\0\0\0\0' + text('/fixture/tree') + text(branch) + text('main') + text(title) + text('') + text('') + b'\0' + integer(0, 'I') * 4 + text('') + b'\0' + integer(0, 'i') for identity, branch, title in self.trees)
                        send(connection, b'\x98' + integer(1) + integer(int(self.topology), 'H') + (entry if self.topology else b'') + integer(len(self.trees), 'H') + trees)
                    elif tag == 0x0c:
                        tab = integer(5) + integer(0, 'H') + integer(1, 'H') + text('Tab') + integer(0, 'H')
                        send(connection, b'\x88' + request + frame[9:18] + text('Workspace') + integer(1, 'H') + tab)
                    elif tag == 0x08:
                        pane = integer(17) + b'\0' + integer(29)
                        send(connection, b'\x86' + request + frame[9:26] + integer(1, 'H') + pane)
                    elif tag == 0x1b:
                        if not self.ack_ignored:
                            self.status = 3
                    else:
                        if tag == 0x1e and self.bump_on_send:
                            self.generation += 1
                        send(connection, b'\xa1' + request)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as error:
            self.errors.append(error)

    def close(self):
        self.stop.set()
        self.thread.join()
        self.listener.close()
        for worker in self.workers:
            worker.join()
        assert not self.errors, self.errors


def environment(root):
    env = {key: value for key, value in os.environ.items() if not key.startswith('TELAR_')}
    for key in ['HOME', 'XDG_RUNTIME_DIR', 'XDG_DATA_HOME', 'XDG_CONFIG_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME', 'TMPDIR']:
        directory = root / key.lower()
        directory.mkdir(exist_ok=True)
        env[key] = str(directory)
    return env


def check(binary, root):
    env = environment(root)
    fixture = Fixture(root)
    count = 0

    def run(*args, status=0, stdin=None, extra=None):
        nonlocal count
        result = subprocess.run([str(binary), *args, '--socket', str(fixture.path)], env=env | (extra or {}), input=stdin, capture_output=True, timeout=12)
        assert result.returncode == status, (args, result.returncode, result.stdout, result.stderr)
        count += 1
        return result

    try:
        value = json.loads(run('agent', 'list', '--json').stdout)
        assert value['revision'] == 11 and value['agents'][0]['final_message'] == 'Finished\nmessage'
        assert value['agents'][0]['session_id'] == '000102030405060708090a0b0c0d0e0f'
        row = run('agent', 'get', 'fIxTuRe').stdout
        assert row == b'PANE  GEN  STATUS   PROV    WORKSPACE         TAB           TITLE\n17    29   ready    claude  Workspace         Tab           Fixture\n', row
        fixture.duplicate = True
        assert b'more than one agent' in run('agent', 'get', 'fixture', status=1).stderr
        fixture.duplicate = False
        fixture.trees = [(71, 'fix', 'Title')]
        fixture.tree = 71
        run('agent', 'get', 'worktree:fix', '--json')
        run('agent', 'get', 'worktree:tItLe', '--json')
        fixture.trees.append((73, 'fix', 'Other'))
        assert b'more than one worktree' in run('agent', 'get', 'worktree:fix', status=1).stderr
        fixture.trees = []
        fixture.tree = 0
        assert b'no agent matches' in run('agent', 'get', 'missing', status=2).stderr
        assert b'no tracked worktree' in run('agent', 'get', 'worktree:missing', status=2).stderr
        assert run('agent', 'read', '17', '--json').stdout == b'{"pane_id":17,"truncated":true,"exit_code":7,"text":"hello\\n\\u0008\\u000c\\u007f"}\n'
        assert run('pane', 'read', '17').stderr == b'telar pane: older rows were omitted\ntelar pane: the command exited with 7\n'
        assert json.loads(run('pane', 'search', '17', 'hello', '--json').stdout)['matches'] == [{'x': 2, 'y': 8, 'len': 5}]
        assert run('pane', 'search', '17', 'hello').stdout == b'8:2 length=5\n'
        run('pane', 'send-keys', '17', '--stdin', '--enter', stdin=b'hello\r\n\n')
        sends = [(when, frame) for when, frame in fixture.frames if frame[0] == 0x1e]
        assert sends[-1][0] - sends[-2][0] >= .14
        assert sends[-2][1][25] == 0 and sends[-2][1][30:35] == b'hello'
        assert sends[-1][1][25] == 2
        run('pane', 'send-keys', '17', '--stdin', stdin=b'\n', status=1)
        for code, message in [(1, b'pane not found'), (10, b'pane already exited'), (12, b'focus')]:
            fixture.refusal = (0x1e, code)
            run('pane', 'send-keys', '17', 'hello', status=2 if code in (1, 10) else 1)
        fixture.refusal = None
        for action, extra in [('get', []), ('wait', ['--until', 'idle']), ('interrupt', []), ('acknowledge', []), ('prompt', ['hello']), ('report-session', ['session-1'])]:
            run('agent', action, '17', *extra, '--json')
        for action, extra in [('report-title', ['Hello']), ('report-state', ['working']), ('report-command', ['started', 'printf hello', '--provider', 'claude'])]:
            result = run('agent', action, '--current', *extra, '--json', extra={'TELAR_PANE_ID': '17', 'TELAR_PANE_GENERATION': '29'})
            assert json.loads(result.stdout) == {'pane_id': 17, 'pane_generation': 29, 'accepted': True}
        for code, message in [(9, b'waiting for a decision'), (12, b'focus'), (13, b'prompt budget')]:
            fixture.refusal = (0x1e, code)
            assert message in run('agent', 'prompt', '17', 'hello', status=1).stderr
        fixture.refusal = None
        run('agent', 'prompt', '17', 'hello', extra={'TELAR_PANE_ID': '19', 'TELAR_SOCKET_PATH': str(fixture.path)})
        assert fixture.frames[-1][1][-9:] == b'\x01' + integer(19)
        run('agent', 'prompt', '17', 'hello', extra={'TELAR_PANE_ID': '19', 'TELAR_SOCKET_PATH': '/different/runtime.sock'})
        assert fixture.frames[-1][1][-1:] == b'\0'
        fixture.bump_on_send = True
        run('agent', 'prompt', '17', 'hello', '--wait', status=2)
        fixture.bump_on_send = False
        fixture.generation = 29
        fixture.status = 5
        fixture.ack_ignored = True
        assert b'AgentAcknowledgementNotApplied' in run('agent', 'acknowledge', '17', status=1).stderr
        fixture.ack_ignored = False
        fixture.status = 1
        assert b'timed out after 1s; agent is working' in run('agent', 'wait', '17', '--timeout', '1s', status=3).stderr
        fixture.states = [3, 3, 1, 5]
        assert json.loads(run('agent', 'prompt', '17', 'hello', '--wait', '--json').stdout)['status'] == 'done'
        fixture.states = [3, 3, 4]
        run('agent', 'prompt', '17', 'hello', '--wait', status=1)
        fixture.states = [1, 1, 3, 1, 5]
        run('agent', 'prompt', '17', 'hello', '--interrupt', '--wait')
        fixture.status = 3
        assert b'did not start working within 5s' in run('agent', 'prompt', '17', 'hello', '--wait', status=3).stderr
        assert run('pane', 'list', '--json').stdout == b'[]\n'
        run('pane', 'get', '17', status=2)
        fixture.topology = True
        assert json.loads(run('pane', 'get', '17', '--json').stdout)['pane_generation'] == 29
        assert run('pane', 'list').stdout == b'WORKSPACE\tTAB\tPANE\tGENERATION\tLIFECYCLE\n3\t5\t17\t29\trunning\n'
        fixture.texts = ['first', 'first', 'changed']
        watched = run('pane', 'watch', '17', '--count', '2', '--interval-ms', '10').stdout.splitlines()
        assert [json.loads(line)['text'] for line in watched] == ['first', 'changed']
        for action, extra in [('create', []), ('split', ['17', 'horizontal']), ('close', ['17']), ('focus', ['17']), ('resize', ['17', 'left']), ('fullscreen', ['17']), ('scroll', ['17', '-2']), ('copy', ['17', '0,1:2,3'])]:
            value = json.loads(run('pane', action, *extra, '--client', '41', '--json').stdout)
            assert value['action'] == 'pane_' + action and value['status'] == 'applied'
        run('pane', 'create', '--client', '99', status=2)
        focus = run('pane', 'focus', '--current', '--direction', 'left', '--json', extra={'TELAR_PANE_ID': '17', 'TELAR_PANE_GENERATION': '29'})
        assert json.loads(focus.stdout) == {'changed': True, 'focused_pane_id': 19, 'reason': 'focused'}
        run('agent', 'report-title', '17', 'bad\n', status=1)
        assert b'WorktreeCatalogMissing' in run('agent', 'report-title', 'worktree:missing', 'Title', status=1).stderr
        run('pane', 'read', '17', '--lines', '+4', status=1)
        run('agent', 'prompt', '17', '', status=1)
        run('pane', 'copy', '17', '0,1:2,3:4,5', '--client', '41', status=1)
        run('pane', 'list', '--tab', '5', status=1)
    finally:
        fixture.close()
    print(f'{count} pane/agent CLI contract cases passed')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--telar', type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='pane-agent-', dir=os.environ.get('TMPDIR')) as directory:
        check(args.telar.resolve(), Path(directory))


if __name__ == '__main__':
    main()
