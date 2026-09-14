#!/usr/bin/env python3
"""Capture the native chrome at its three text sizes against an isolated macOS runtime.

One run per configuration: the base terminal size and `gui.chrome.scale = 1.5`.
Each shows the top bar pills, the tab strip, the sidebar header and the
new-context form, then the same window with the form closed.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).parent))
from gui_multiplexer import Actions  # noqa: E402

ESCAPE = 53
TAB = 48

CONFIGS = {
    'base': "return { api_version = 2, theme = 'osaka-jade', gui = { window = { titlebar = false } } }",
    'scaled': "return { api_version = 2, theme = 'osaka-jade', gui = { window = { titlebar = false }, chrome = { scale = 1.5 } } }",
}


def exercise(binary, directory, env, library, actions, name, config):
    script = directory / f'{name}.json'
    script.write_text(json.dumps(actions.items))
    with (directory / f'{name}.log').open('w') as log:
        subprocess.run([str(binary), 'gui', '--config', str(config), '/bin/sh'], cwd=directory,
                       env=dict(env, DYLD_INSERT_LIBRARIES=str(library), TELAR_GUI_ACTIONS=str(script)),
                       stdout=log, stderr=log, timeout=100, check=True)


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
        records = {}
        for name, source in CONFIGS.items():
            config = directory / f'{name}.lua'
            config.write_text(source)
            actions = Actions(directory)
            actions.rename('W', 'telar')
            actions.prefix('c', 8)
            actions.rename('T', 'editor')
            actions.record(f'{name}-size')
            actions.prefix('N', 45, shift=True)
            actions.text('docs')
            actions.key('\t', TAB)
            actions.text('~/sand')
            actions.items.extend([{}, {}, {}])
            actions.capture(f'slice-7-{name}-new-context')
            actions.key('\x1b', ESCAPE)
            actions.items.extend([{}, {}])
            actions.capture(f'slice-7-{name}-multiplexer')
            exercise(binary, directory, env, library, actions, name, config)
            records[name] = tuple(map(int, (directory / f'{name}-size').read_text().split()))
        # The chrome scale must not change the PTY grid: same rows and columns.
        assert records['base'][1:] == records['scaled'][1:], records
        print(records)
    finally:
        subprocess.run([str(binary), 'server', 'stop'], env=env, stdout=subprocess.DEVNULL,
                       timeout=10, check=False)


if __name__ == '__main__':
    main()
