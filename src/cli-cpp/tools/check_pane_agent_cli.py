#!/usr/bin/env python3
"""An isolated runtime stack and window fixture for pane and agent CLI checks."""
import json
import re
from pathlib import Path
import shutil
import socket
import struct
import threading
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tests'))
from pane_agent_test import environment, integer, receive, send


def result(process):
    return {'status': process.returncode, 'stdout': process.stdout.decode(errors='backslashreplace'), 'stderr': process.stderr.decode(errors='backslashreplace')}



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
