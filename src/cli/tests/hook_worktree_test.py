#!/usr/bin/env python3
"""Claude Code's WorktreeRemove hook: what stays on disk and what the runtime is told."""
import argparse
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import threading

FORGET_WORKTREE = 0x3e
REQUEST_RUNTIME_STATE = 0x14


def integer(value, code='Q'):
    return struct.pack('<' + code, value)


def text(value):
    value = value.encode()
    return integer(len(value), 'H') + value


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


class Runtime:
    """A runtime socket whose catalog tracks the given worktrees, by identity and path."""

    def __init__(self, path, worktrees):
        self.path = path
        self.worktrees = worktrees
        self.frames = []
        self.errors = []
        self.listener = socket.socket(socket.AF_UNIX)
        self.listener.bind(str(path))
        self.listener.listen()
        self.listener.settimeout(.05)
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.accept)
        self.thread.start()

    def accept(self):
        while not self.stop.is_set():
            try:
                connection, _ = self.listener.accept()
            except TimeoutError:
                continue
            try:
                self.serve(connection)
            except (BrokenPipeError, ConnectionResetError):
                pass
            except Exception as error:
                self.errors.append(error)

    def serve(self, connection):
        with connection:
            connection.settimeout(10)
            hello = receive(connection)
            if hello is None:
                return
            assert hello[:9] == b'TELARIPC\x01'
            send(connection, b'TELARIPC\x02' + hello[9:])
            while (frame := receive(connection)) is not None:
                self.frames.append(frame)
                if frame[0] == REQUEST_RUNTIME_STATE:
                    entries = b''.join(integer(identity) + integer(3) + b'\0\0\0\0' + text(str(path)) + text(path.name) + text('main') + text('') + text('') + text('')
                                       + b'\0' + integer(0, 'I') * 4 + text('') + b'\0' + integer(0, 'i') for identity, path in self.worktrees.items())
                    send(connection, b'\x98' + integer(1) + integer(0, 'H') + integer(len(self.worktrees), 'H') + entries)
                else:
                    send(connection, b'\xa1' + frame[1:9])

    def forgotten(self):
        return [struct.unpack('<Q', frame[9:17])[0] for frame in self.frames if frame[0] == FORGET_WORKTREE]

    def close(self):
        self.stop.set()
        self.thread.join()
        self.listener.close()
        assert not self.errors, self.errors


def git(*args, cwd, env):
    return subprocess.run(['git', *args], cwd=cwd, env=env, check=True, capture_output=True, text=True).stdout


def check(binary, root):
    env = {key: value for key, value in os.environ.items() if not key.startswith(('TELAR_', 'GIT_'))}
    env.update({'HOME': str(root), 'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': os.devnull,
                'GIT_AUTHOR_NAME': 'fixture', 'GIT_AUTHOR_EMAIL': 'fixture@example.invalid',
                'GIT_COMMITTER_NAME': 'fixture', 'GIT_COMMITTER_EMAIL': 'fixture@example.invalid'})
    repository = root / 'repository'
    repository.mkdir()
    git('init', '-q', '-b', 'main', cwd=repository, env=env)
    (repository / 'tracked.txt').write_text('base\n')
    git('add', 'tracked.txt', cwd=repository, env=env)
    git('-c', 'commit.gpgsign=false', 'commit', '-q', '-m', 'base', cwd=repository, env=env)
    dirty = root / 'dirty'
    clean = root / 'clean'
    for tree in (dirty, clean):
        git('worktree', 'add', '-q', '-b', tree.name, str(tree), cwd=repository, env=env)
    (dirty / 'tracked.txt').write_text('edited, not committed\n')
    (dirty / 'untracked.txt').write_text('new, not added\n')
    runtime = Runtime(root / 'runtime.sock', {71: dirty, 73: clean})

    def remove(tree):
        event = {'session_id': 'fixture', 'hook_event_name': 'WorktreeRemove', 'cwd': str(repository), 'worktree_path': str(tree)}
        return subprocess.run([str(binary), 'hook', 'claude', '--socket', str(runtime.path)], input=json.dumps(event).encode(),
                              env=env | {'TELAR_PANE_ID': '17', 'TELAR_PANE_GENERATION': '29'}, capture_output=True, timeout=30)

    try:
        # Git refuses to remove a checkout with changes: they stay for review and the runtime keeps tracking it.
        kept = remove(dirty)
        assert kept.returncode == 0, kept
        assert (dirty / 'tracked.txt').read_text() == 'edited, not committed\n' and (dirty / 'untracked.txt').exists()
        assert 71 not in runtime.forgotten(), runtime.forgotten()

        listed = git('worktree', 'list', '--porcelain', cwd=repository, env=env)
        assert f'worktree {dirty}\n' in listed, listed

        # A clean checkout goes, and the runtime forgets it.
        removed = remove(clean)
        assert removed.returncode == 0, removed
        assert not clean.exists()
        assert runtime.forgotten() == [73], runtime.forgotten()
    finally:
        runtime.close()
    print('worktree remove hook cases passed')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--telar', type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='hook-worktree-', dir=os.environ.get('TMPDIR')) as directory:
        check(args.telar.resolve(), Path(directory).resolve())


if __name__ == '__main__':
    main()
