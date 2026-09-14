#!/usr/bin/env python3
"""Capture the native command palette in its three modes against an isolated macOS runtime."""
import argparse
import os
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).parent))
from gui_multiplexer import Actions, exercise  # noqa: E402

BACKSPACE = 51
ESCAPE = 53


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
        actions.rename('W', 'telar')
        actions.record('initial')
        actions.prefix('c', 8)
        actions.rename('T', 'editor')
        actions.record('tab-two')
        actions.prefix('g', 5)
        actions.items.extend([{}, {}])
        actions.capture('slice-6-palette-goto')
        actions.key('\x7f', BACKSPACE)
        actions.text('>')
        actions.items.extend([{}, {}])
        actions.capture('slice-6-palette-actions')
        actions.text('new tab')
        actions.items.extend([{}, {}])
        actions.capture('slice-6-palette-actions-filtered')
        actions.key('\r', 36)
        actions.items.extend([{}, {}, {}])
        actions.record('after-action')
        actions.prefix('?', 44, shift=True)
        actions.items.extend([{}, {}])
        actions.capture('slice-6-palette-suggest')
        actions.key('\x1b', ESCAPE)
        actions.items.extend([{}, {}])
        actions.record('closed')
        exercise(binary, directory, env, library, actions, 'palette')
        read = lambda name: tuple(map(int, (directory / name).read_text().split()))
        records = {name: read(name) for name in ['initial', 'tab-two', 'after-action', 'closed']}
        # ">new tab" matches only "New tab"; Enter ran it, so the shell after it is a third one.
        assert len({records[name][0] for name in ['initial', 'tab-two', 'after-action']}) == 3, records
        assert records['after-action'] == records['closed'], records
        print(records)
    finally:
        subprocess.run([str(binary), 'server', 'stop'], env=env, stdout=subprocess.DEVNULL,
                       timeout=10, check=False)


if __name__ == '__main__':
    main()
