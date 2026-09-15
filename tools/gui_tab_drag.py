#!/usr/bin/env python3
"""Verify native tab dragging, cancellation and reconnect against an isolated runtime."""
import argparse
import json
import os
from pathlib import Path
import subprocess

from gui_multiplexer import Actions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('directory', type=Path)
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

    def run(actions, name):
        script = directory / f'{name}.json'
        script.write_text(json.dumps(actions.items))
        with (directory / f'{name}.log').open('w') as log:
            subprocess.run([str(binary), 'gui', '--no-config', '/bin/sh'], cwd=directory,
                           env=dict(env, DYLD_INSERT_LIBRARIES=str(library), TELAR_GUI_ACTIONS=str(script)),
                           stdout=log, stderr=log, timeout=100, check=True)

    def order(actions, labels, name):
        actions.items.extend([{}] * 4)
        actions.items.append(dict(tab_order=labels, capture_tabs=str(directory / f'{name}.png')))

    def drag(actions, source, target, fraction, cancel=False):
        actions.items.append(dict(pointer='press', control=source))
        actions.items.append(dict(pointer='drag', control=target, fraction=fraction))
        actions.items.extend([{}] * 2)
        if cancel:
            actions.key('\x1b', 53)
        actions.items.append(dict(pointer='release', reuse_pointer=True))

    try:
        actions = Actions(directory)
        actions.rename('T', 'API')
        actions.prefix('c', 8)
        actions.rename('T', 'Web')
        actions.prefix('c', 8)
        actions.rename('T', 'Jobs')
        order(actions, ['API', 'Web', 'Jobs'], 'before')
        drag(actions, 'Jobs', 'API', .1)
        order(actions, ['Jobs', 'API', 'Web'], 'moved-left')
        drag(actions, 'Jobs', 'Web', .9)
        order(actions, ['API', 'Web', 'Jobs'], 'moved-right')
        drag(actions, 'Jobs', 'API', .1, cancel=True)
        order(actions, ['API', 'Web', 'Jobs'], 'cancelled')
        drag(actions, 'Jobs', 'API', .1)
        order(actions, ['Jobs', 'API', 'Web'], 'final')
        run(actions, 'drag')
        reconnect = Actions(directory)
        order(reconnect, ['Jobs', 'API', 'Web'], 'reconnected')
        run(reconnect, 'reconnect')
        print('Native drag in both directions, Escape cancellation and reconnect passed', flush=True)
    finally:
        subprocess.run([str(binary), 'server', 'stop'], env=env, stdout=subprocess.DEVNULL,
                       timeout=10, check=False)


if __name__ == '__main__':
    main()
