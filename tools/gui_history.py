#!/usr/bin/env python3
"""Capture the native command history against an isolated macOS runtime."""
import argparse
import os
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).parent))
from gui_multiplexer import Actions, exercise  # noqa: E402

RETURN = 36
ESCAPE = 53
BACKSPACE = 51
SLASH = 44
KEY_O = 31
CAPTURES = ['history-list', 'history-inspector', 'history-failed', 'history-search']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('directory', type=Path, help='new short /tmp directory')
    args = parser.parse_args()
    binary = args.binary.resolve()
    directory = args.directory.resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    library = directory / 'driver.dylib'
    subprocess.run(['clang', '-dynamiclib', '-fobjc-arc', '-framework', 'AppKit',
                    str(Path(__file__).with_name('gui_actions.m')), '-o', str(library)], check=True)
    env = {key: value for key, value in os.environ.items() if not key.startswith('TELAR_')}
    env.update(TELAR_SOCKET=str(directory / 'runtime.sock'), TELAR_HISTORY=str(directory / 'history.db'))
    subprocess.run([str(binary), 'server', '--background', '--no-config'], env=env, cwd=directory, check=True)
    try:
        actions = Actions(directory)
        actions.items.append(dict(activate=True, resize=[1180, 720]))
        actions.items.extend([{}] * 4)
        actions.rename('W', 'telar')
        # A few commands in the shell so the page has rows of every status.
        for command in ['ls /', 'false', 'sleep 1', 'echo done']:
            actions.text(command)
            actions.key('\r', RETURN)
            actions.items.extend([{}] * 4)
        actions.items.extend([{}] * 8)
        actions.record('initial')
        actions.prefix('/', SLASH)
        actions.items.extend([{}] * 10)
        actions.capture('history-list')
        actions.key('o', KEY_O, ctrl=True)
        actions.items.extend([{}] * 10)
        actions.capture('history-inspector')
        actions.key('\x1b', ESCAPE)
        actions.items.extend([{}] * 4)
        actions.text('!')
        actions.items.extend([{}] * 10)
        actions.capture('history-failed')
        actions.key('\x7f', BACKSPACE)
        actions.text('ec')
        actions.items.extend([{}] * 10)
        actions.capture('history-search')
        actions.key('\x1b', ESCAPE)
        actions.items.extend([{}] * 4)
        actions.record('closed')
        exercise(binary, directory, env, library, actions, 'history')
        for name in CAPTURES:
            assert (directory / f'{name}.png').exists(), name
        read = lambda name: tuple(map(int, (directory / name).read_text().split()))  # noqa: E731
        assert read('initial') == read('closed'), 'history must leave the shell and its size alone'
        print(directory)
    finally:
        subprocess.run([str(binary), 'server', 'stop'], env=env, stdout=subprocess.DEVNULL,
                       timeout=10, check=False)


if __name__ == '__main__':
    main()
