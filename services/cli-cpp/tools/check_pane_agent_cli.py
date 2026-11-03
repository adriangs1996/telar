#!/usr/bin/env python3
"""Compare pane/agent commands stack against stack, retaining every difference."""
import argparse
import json
import os
import re
from pathlib import Path
import shutil
import socket
import struct
import threading
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tests'))
from pane_agent_test import environment, integer, receive, send


def result(process):
    return {'status': process.returncode, 'stdout': process.stdout.decode(errors='backslashreplace'), 'stderr': process.stderr.decode(errors='backslashreplace')}


def invalid_cases():
    yield ['pane']
    yield ['agent']
    for family in ['pane', 'agent']:
        yield [family, 'missing']
        for action in (['read', 'send-keys', 'focus', 'list', 'get', 'watch', 'search', 'create', 'split', 'close', 'resize', 'fullscreen', 'scroll', 'copy'] if family == 'pane' else ['list', 'get', 'wait', 'prompt', 'read', 'interrupt', 'acknowledge', 'report-session', 'report-title', 'report-state', 'report-command']):
            yield [family, action, '--bogus']
            if action != 'list':
                yield [family, action]
    for action in ['read', 'get', 'watch', 'search', 'send-keys']:
        yield ['pane', action, 'name']
    for family in ['pane', 'agent']:
        for arg in ['0', '2001', '-1', '65536', 'x', '']:
            yield [family, 'read', '17', '--lines', arg]
        yield [family, 'read', '17', '--lines']
        yield [family, 'read', '17', '--source', 'missing']
        yield [family, 'list', '--socket', 'a', '--socket', 'b']
    for arg in ['0', '86401', '-1', 'x', '']:
        yield ['agent', 'wait', '17', '--timeout', arg]
    for arg in ['unknown', 'missing', '']:
        yield ['agent', 'wait', '17', '--until', arg]
    for arg in ['', 'x' * 65537]:
        yield ['agent', 'prompt', '17', arg]
        yield ['pane', 'send-keys', '17', arg]
    yield ['pane', 'search', '17', '']
    yield ['pane', 'search', '17', 'x' * 129]
    for arg in ['0', '9', '60001', '-1', 'bad']:
        yield ['pane', 'watch', '17', '--interval-ms', arg]
    for arg in ['0', '-1', 'bad']:
        yield ['pane', 'watch', '17', '--count', arg]
    for arg in ['bad', '0,0', '0,0:1,1:2,2', '0,-1:1,1', '65536,0:1,1']:
        yield ['pane', 'copy', '17', arg, '--client', '1']
    for arg in ['0', '-1', 'name', '18446744073709551616']:
        yield ['pane', 'close', arg, '--client', '1']
    yield ['pane', 'focus', '--current']
    yield ['pane', 'focus', '17', '--direction', 'left']
    yield ['pane', 'list', '--tab', '1']
    yield ['pane', 'list', '--workspace', '0']
    yield ['pane', 'create', '--client', '1', '--json', '--json']
    for arg in ['\n', '\x7f', 'x' * 97]:
        yield ['agent', 'report-title', '17', arg]
    yield ['agent', 'report-session', '17', '']
    yield ['agent', 'report-session', '17', 'x' * 65]
    yield ['agent', 'report-state', '17', 'bad']
    yield ['agent', 'report-command', '17', 'started', 'true']
    yield ['agent', 'report-command', '17', 'bad', 'true', '--provider', 'claude']
    yield ['agent', 'report-command', '17', 'started', 'true', '--provider', 'claude', '--exit-code', '0']


class Window:
    """A native interactive peer verifies routing/replies on both wire schemas.

    Real effects are checked separately by check_pane_gui.py against the C++ GUI.
    """
    def __init__(self, stack):
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.settimeout(10)
        self.socket.connect(str(stack.socket))
        schema = stack.invoke(['server', 'endpoint']).stdout.splitlines()[-1]
        send(self.socket, b'TELARIPC\x01' + schema)
        assert receive(self.socket) == b'TELARIPC\x02' + schema
        send(self.socket, b'\x14' + integer(123) + b'\x01')
        send(self.socket, b'\x33' + integer(77))
        while True:
            frame = receive(self.socket)
            assert frame is not None
            if frame[0] == 0xad:
                assert frame[9] == 1, frame.hex()
                stack.ids['client_id'], stack.ids['client_generation'] = struct.unpack_from('<QQ', frame, 10)
                break
        self.status = 1
        self.errors = []
        self.thread = threading.Thread(target=self.respond)
        self.thread.start()

    def respond(self):
        try:
            while (frame := receive(self.socket)) is not None:
                if frame[0] == 0xae:
                    reply = bytearray(frame)
                    reply[0], reply[26] = 0x36, self.status
                    send(self.socket, reply)
        except OSError:
            pass
        except Exception as error:
            self.errors.append(str(error))

    def close(self):
        self.socket.shutdown(socket.SHUT_RDWR)
        self.socket.close()
        self.thread.join()
        assert not self.errors, self.errors


class Stack:
    def __init__(self, binary, root, probe=None, fixture=None):
        self.binary, self.root, self.probe = binary, root, probe
        self.env = environment(root)
        self.socket = root / 'r.sock'
        self.log = (root / 'runtime.log').open('wb')
        self.server = subprocess.Popen([str(binary), 'server', '--socket', str(self.socket), '--no-config', '--fresh'], env=self.env, stdout=self.log, stderr=self.log)
        try:
            deadline = time.monotonic() + 15
            while not self.socket.exists():
                if self.server.poll() is not None or time.monotonic() > deadline:
                    self.log.flush()
                    raise RuntimeError((root / 'runtime.log').read_text())
                time.sleep(.02)
            command = root / 'claude'
            shutil.copyfile(fixture or probe, command)
            command.chmod(0o755)
            if probe:
                opened = subprocess.run([str(probe), 'seed', str(self.socket), str(root), str(command)], env=self.env, capture_output=True, check=True)
            else:
                opened = self.invoke(['workspace', 'create', '--directory', str(root), '--name', 'Fixture', '--json', '--', str(command)])
            self.ids = json.loads(opened.stdout)
            pane = self.invoke(['pane', 'get', str(self.ids['pane_id']), '--json'])
            assert pane.returncode == 0, (self.ids, pane.returncode, pane.stdout, pane.stderr, self.invoke(['pane', 'list', '--json']).stdout, (root / 'runtime.log').read_text())
            self.ids.update(json.loads(pane.stdout))
            self.current = {'TELAR_PANE_ID': str(self.ids['pane_id']), 'TELAR_PANE_GENERATION': str(self.ids['pane_generation']), 'TELAR_WORKSPACE_ID': str(self.ids['workspace_id']), 'TELAR_TAB_ID': str(self.ids['tab_id']), 'TELAR_SOCKET_PATH': str(self.socket)}
            deadline = time.monotonic() + 10
            while not json.loads(self.invoke(['agent', 'list', '--json']).stdout)['agents']:
                if time.monotonic() > deadline:
                    raise RuntimeError('fake claude process was not observed')
                time.sleep(.1)
        except BaseException:
            self.close()
            raise

    def invoke(self, args, stdin=None, current=False):
        # Literal '--' belongs after CLI socket options.
        args = [str(self.ids['client_id']) if str(arg) == '<CLIENT>' else str(arg) for arg in args]
        separator = args.index('--') if '--' in args else len(args)
        args[separator:separator] = ['--socket', str(self.socket)]
        return subprocess.run([str(self.binary), *args], env=self.env | {'TELAR_SOCKET': str(self.socket)} | (self.current if current else {}), input=stdin, capture_output=True, timeout=35)

    def normalize(self, process):
        data = result(process)
        data['stdout'] = data['stdout'].replace(str(self.root), '<ROOT>')
        def field(match):
            key, raw = match.group(2), match.group(3)
            if key in ['revision', 'status_age_s', 'session_id']:
                value = '"<TIME_OR_ID>"'
            else:
                decoded = json.loads(raw)
                normalized = self.identity(key, decoded)
                value = json.dumps(normalized) if normalized != decoded else raw
            return match.group(1) + value
        data['stdout'] = re.sub(r'("(revision|status_age_s|session_id|[a-z_]*_id|pane_generation|client_generation)":)("[^"\\]*(?:\\.[^"\\]*)*"|[0-9]+)', field, data['stdout'])
        return data

    def identity(self, key, value):
        if not value:
            return value
        if key in self.ids and self.ids[key] == value:
            return '<' + key + '>'
        return value

    def close(self):
        if self.server.poll() is None:
            self.invoke(['server', 'stop'])
            try:
                self.server.wait(timeout=12)
            except subprocess.TimeoutExpired:
                self.server.terminate()
                self.server.wait(timeout=5)
        self.log.close()


def checks(zig, cpp, probe, root):
    output = []
    zroot, croot = root / 'z', root / 'c'
    zroot.mkdir(); croot.mkdir()
    stacks = []
    try:
        stacks.append(Stack(zig, zroot, fixture=probe))
        stacks.append(Stack(cpp, croot, probe))
        for args in invalid_cases():
            pair = [result(stack.invoke(args)) for stack in stacks]
            output.append({'args': [arg if len(arg) < 150 else f'<{len(arg)} bytes>' for arg in args], 'zig': pair[0], 'cpp': pair[1], 'equal': pair[0] == pair[1], 'scope': 'validation'})
        def compare(args, stdin=None, current=False):
            pair = [stack.normalize(stack.invoke(args, stdin, current)) for stack in stacks]
            output.append({'args': args, 'zig': pair[0], 'cpp': pair[1], 'equal': pair[0] == pair[1], 'scope': 'runtime'})
        compare(['pane', 'list', '--json'])
        for args in [
            ['pane', 'get', '--current', '--json'],
            ['pane', 'list', '--workspace', '--current', '--tab', '--current', '--json'],
            ['pane', 'get', '999999', '--json'], ['pane', 'get', '0', '--json'],
            ['pane', 'read', '--current', '--source', 'screen', '--json'],
            ['pane', 'watch', '--current', '--count', '1', '--jsonl'],
            ['pane', 'search', '--current', 'hello', '--json'],
            ['agent', 'get', 'missing', '--json'],
            ['agent', 'get', 'worktree:missing', '--json'],
            ['agent', 'report-title', 'worktree:missing', 'Title', '--json'],
            ['agent', 'report-state', 'worktree:missing', 'ready', '--json'],
            ['agent', 'report-command', 'worktree:missing', 'started', 'true', '--provider', 'claude'],
            ['agent', 'report-title', '--current', 'Fixture "title"', '--json'],
            ['agent', 'get', 'fixture \"TITLE\"', '--json'],
            ['agent', 'get', 'fixture \"TITLE\"'],
            ['agent', 'report-title', '--current', 'Fíxture 🧵', '--json'],
            ['agent', 'get', '--current'],
            ['agent', 'report-title', '--current', '', '--json'],
            ['agent', 'report-state', '--current', 'ready', '--event', 'fixture', '--json'],
            ['agent', 'report-session', '--current', 'fixture-session'],
            ['agent', 'get', '--current', '--json'], ['agent', 'list', '--json'],
            ['agent', 'wait', '--current', '--until', 'idle', '--timeout', '1s', '--json'],
            ['agent', 'wait', '--current', '--until', 'working', '--timeout', '1s'],
            ['agent', 'read', '--current', '--json'],
            ['pane', 'read', '--current', '--lines', '+4', '--json'],
            ['pane', 'read', '--current', '--lines', '4_0', '--json'],
            ['agent', 'acknowledge', '--current', '--json'],
            ['agent', 'interrupt', '--current', '--json'],
            ['agent', 'report-command', '--current', 'started', 'printf hello', '--provider', 'claude', '--json'],
            ['agent', 'report-command', '--current', 'finished', 'printf hello', '--provider', 'claude', '--exit-code', '0', '--json'],
            ['agent', 'report-state', '--current', 'ready', '--blocked-reason', 'question', '--json'],
            ['agent', 'report-state', '--current', 'ready', '--event', '\n', '--json'],
            ['agent', 'report-session', '--current', 'bad reference'],
            ['pane', 'send-keys', '--current', '--stdin'],
            ['pane', 'focus', '--current', '--direction', 'left', '--json'],
            ['pane', 'create', '--client', '999999', '--json'],
        ]:
            compare(args, stdin=b'\n' if args[-1] == '--stdin' else None, current=True)
        # Each routed verb is compared for discovery failure; GUI effects are a separate pass.
        for action, tail in [('split', ['17', 'horizontal']), ('close', ['17']), ('focus', ['17']), ('resize', ['17', 'left']), ('fullscreen', ['17']), ('scroll', ['17', '-1']), ('copy', ['17', '0,0:1,1'])]:
            compare(['pane', action, *tail, '--client', '999999', '--json'])
        windows = []
        try:
            for stack in stacks:
                windows.append(Window(stack))
            for status in [1, 2, 3]:
                for window in windows:
                    window.status = status
                for action, tail in [('create', []), ('split', ['17', 'horizontal']), ('close', ['17']), ('focus', ['17']), ('resize', ['17', 'left']), ('fullscreen', ['17']), ('scroll', ['17', '-2']), ('copy', ['17', '0,1:2,3'])]:
                    compare(['pane', action, *tail, '--client', '<CLIENT>', '--json'])
                    compare(['pane', action, *tail, '--client', '<CLIENT>'])
        finally:
            for window in windows:
                window.close()
        compare(['pane', 'send-keys', '--current', 'hello', '--enter'], current=True)
        time.sleep(.3)
        compare(['pane', 'search', '--current', 'hello', '--json'], current=True)
        compare(['pane', 'read', '--current', '--lines', '1', '--json'], current=True)
        compare(['agent', 'report-state', '--current', 'blocked', '--blocked-reason', 'question', '--json'], current=True)
        compare(['agent', 'prompt', '--current', 'hello'], current=True)
        compare(['agent', 'report-state', '--current', 'ready', '--json'], current=True)
        compare(['agent', 'prompt', '--current', 'hello'], current=True)
        compare(['agent', 'prompt', '--current', 'hello', '--wait', '--timeout', '1s'], current=True)
    finally:
        for stack in stacks:
            stack.close()
    return output


def main():
    parser = argparse.ArgumentParser()
    for name in ['zig', 'cpp', 'probe', 'scratch', 'output']:
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    args.scratch.mkdir(exist_ok=True, parents=True)
    with tempfile.TemporaryDirectory(prefix='pa-', dir=args.scratch) as directory:
        rows = checks(args.zig.resolve(), args.cpp.resolve(), args.probe.resolve(), Path(directory))
    args.output.write_text(json.dumps(rows, indent=2) + '\n')
    differences = [row for row in rows if not row['equal']]
    print(f'{len(rows) - len(differences)}/{len(rows)} cases match Zig; {len(differences)} differences')
    for row in differences:
        print(row['args'], '\n Zig:', row['zig'], '\n C++:', row['cpp'])
    return bool(differences)


if __name__ == '__main__':
    raise SystemExit(main())
