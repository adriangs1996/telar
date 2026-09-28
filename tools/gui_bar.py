#!/usr/bin/env python3
"""Exercise the native bottom bar and its panels against a real isolated macOS runtime.

Runs `docs/examples/bar/config.lua` with a usage document written for the
current time, then hovers, clicks, narrows the window and enters prefix mode,
capturing the window after each step.
"""
import argparse
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import subprocess

EXAMPLE = Path(__file__).resolve().parent.parent / 'docs' / 'examples' / 'bar' / 'config.lua'


def iso(moment):
    return moment.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def usage_document(now):
    hour = timedelta(hours=1)
    return {'providers': {
        'claude': {
            'name': 'Claude',
            'url': 'https://claude.ai/settings/usage',
            'windows': [
                {'id': '5h', 'title': 'Current session', 'used': 22, 'resets_at': iso(now + 1.5 * hour), 'seconds': 5 * 3600},
                {'id': '7d', 'title': 'This week', 'used': 50, 'resets_at': iso(now + 31 * hour), 'seconds': 7 * 86400},
                {'id': 'F', 'title': 'Fable this week', 'used': 42, 'resets_at': iso(now + 31 * hour), 'seconds': 7 * 86400},
            ],
        },
        'codex': {
            'name': 'Codex',
            'url': 'https://chatgpt.com/codex/settings/usage',
            'windows': [
                {'id': '7d', 'title': 'This week', 'used': 0, 'resets_at': iso(now + 150 * hour), 'seconds': 7 * 86400},
            ],
            'credits': [{'title': '1 free full reset', 'expires_at': iso(now + 26 * 24 * hour)}],
        },
    }}


class Actions:
    def __init__(self, directory):
        self.directory = directory
        self.items = [dict(activate=True), dict(resize=[1400, 820])]

    def settle(self, steps=6):
        self.items.extend([{}] * steps)

    def pointer(self, kind, control):
        self.items.append(dict(activate=True, pointer=kind, control=control, wait_label=control))

    def key(self, text, code=0, **modifiers):
        self.items.append(dict(key=text, code=code, **modifiers))

    def capture(self, name):
        """Records the native state and, with Screen Recording permission, the window."""
        self.settle()
        self.items.append(dict(record=str(self.directory / f'{name}.json')))
        self.items.append(dict(capture=str(self.directory / f'{name}.png')))


def labels(directory, name):
    record = json.loads((directory / f'{name}.json').read_text())
    return {control.get('label') for control in record.get('controls', [])}, record


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
    usage = directory / 'usage.json'
    usage.write_text(json.dumps(usage_document(datetime.now(timezone.utc))))
    env = {key: value for key, value in os.environ.items() if not key.startswith('TELAR_')}
    env.update(TELAR_SOCKET=str(directory / 'runtime.sock'), TELAR_HISTORY=str(directory / 'history.db'),
               TELAR_USAGE_FILE=str(usage))
    subprocess.run([str(binary), 'server', '--background', '--no-config'], env=env, cwd=directory, check=True)
    try:
        actions = Actions(directory)
        actions.items.append(dict(wait_label='claude', wait_seconds=10))
        actions.capture('bar')
        actions.pointer('move', 'claude')
        actions.capture('tooltip')
        actions.pointer('press', 'claude')
        actions.pointer('release', 'claude')
        actions.items.append(dict(wait_label='Refresh', wait_seconds=10))
        actions.capture('panel')
        actions.key('\x1b', 53)
        actions.capture('closed')
        actions.pointer('press', 'codex')
        actions.pointer('release', 'codex')
        actions.items.append(dict(wait_label='Open in browser', wait_seconds=10))
        actions.capture('codex-panel')
        actions.key('\x1b', 53)
        actions.capture('codex-closed')
        actions.key('b', 11, ctrl=True)
        actions.capture('prefix')
        actions.key('\x1b', 53)
        # A tiling window manager may refuse the resize; the check below
        # reports the narrow bar as skipped instead of failing then.
        actions.items.append(dict(resize=[520, 820]))
        actions.capture('narrow')
        script = directory / 'bar.json'
        script.write_text(json.dumps(actions.items))
        with (directory / 'bar.log').open('w') as log:
            subprocess.run([str(binary), 'gui', '--config', str(EXAMPLE), '/bin/sh'], cwd=directory,
                           env=dict(env, DYLD_INSERT_LIBRARIES=str(library), TELAR_GUI_ACTIONS=str(script)),
                           stdout=log, stderr=log, timeout=180, check=True)
        bar, _ = labels(directory, 'bar')
        assert {'claude', 'codex'} <= bar, bar
        panel, _ = labels(directory, 'panel')
        assert {'Refresh', 'Open in browser', 'Close panel'} <= panel, panel
        closed, _ = labels(directory, 'closed')
        assert 'Close panel' not in closed, closed
        codex, _ = labels(directory, 'codex-panel')
        assert 'Open' in codex and 'Close panel' in codex, codex
        assert 'Close panel' not in labels(directory, 'codex-closed')[0]
        prefix, _ = labels(directory, 'prefix')
        assert 'claude' not in prefix, prefix
        narrow, record = labels(directory, 'narrow')
        if record['view_points'][0] <= 600:
            assert 'More bar items' in narrow, narrow
            print('narrow bar: overflow chip present')
        else:
            print(f'narrow bar: skipped, the window stayed {record["view_points"][0]} points wide')
        captured = [name for name in ['bar', 'tooltip', 'panel', 'closed', 'codex-panel', 'prefix', 'narrow']
                    if (directory / f'{name}.png').exists()]
        print(f'native checks passed; window captures: {captured or "none (grant Screen Recording to capture)"}')
    finally:
        subprocess.run([str(binary), 'server', 'stop'], env=env, cwd=directory, check=False)


if __name__ == '__main__':
    main()
