#!/usr/bin/env python3
"""Capture the native fleet sidebar and a peek against a runtime that already runs worktree agents.

Unlike the isolated scripts, this one attaches to the runtime at --socket, so
the task cards show real agents: start a coordinator and a few workers first.
The first pass records the accessibility controls and captures the sidebar;
with --peek LABEL (a task title or agent name) a second pass right-clicks
that card, records and captures the peek, sends TEXT when given and closes
it. Captures need the terminal to hold Screen Recording permission; the
control records do not.
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


def run(binary, directory, env, library, actions, name):
    script = directory / f'{name}.json'
    script.write_text(json.dumps(actions.items))
    with (directory / f'{name}.log').open('w') as log:
        subprocess.run([str(binary), 'gui'], cwd=directory,
                       env=dict(env, DYLD_INSERT_LIBRARIES=str(library), TELAR_GUI_ACTIONS=str(script)),
                       stdout=log, stderr=log, timeout=100, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('directory', type=Path, help='new directory for captures')
    parser.add_argument('--socket', required=True, type=Path)
    parser.add_argument('--peek', help='accessibility label of the agent card to peek at')
    parser.add_argument('--text', help='message the peek sends')
    args = parser.parse_args()
    binary = args.binary.resolve()
    directory = args.directory.resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    library = directory / 'driver.dylib'
    subprocess.run(['clang', '-dynamiclib', '-fobjc-arc', '-framework', 'AppKit',
                    str(Path(__file__).with_name('gui_actions.m')), '-o', str(library)], check=True)
    env = {key: value for key, value in os.environ.items() if not key.startswith('TELAR_')}
    env.update(TELAR_SOCKET=str(args.socket))

    actions = Actions(directory)
    actions.items.extend([{'activate': True}, {}, {}, {}, {}, {}])
    actions.capture('fleet')
    actions.items.append({'record': str(directory / 'controls.json')})
    run(binary, directory, env, library, actions, 'fleet')
    controls = json.loads((directory / 'controls.json').read_text())['controls']
    print('\n'.join(sorted({control['label'] for control in controls})))
    if not args.peek:
        return

    actions = Actions(directory)
    actions.items.extend([{'activate': True}, {}, {}, {}, {}])
    actions.items.append({'wait_label': args.peek})
    actions.items.append({'right_click_label': args.peek})
    actions.items.extend([{}, {}, {}, {}])
    actions.capture('peek')
    actions.items.append({'record': str(directory / 'peek-controls.json')})
    if args.text:
        actions.text(args.text)
        actions.key('\r', 36)
        actions.items.extend([{}, {}, {}, {}])
        actions.capture('sent')
        actions.items.append({'record': str(directory / 'sent-controls.json')})
    else:
        actions.key('\x1b', ESCAPE)
        actions.items.extend([{}, {}])
    run(binary, directory, env, library, actions, 'peek')
    before = {control['label'] for control in controls}
    for name in ['peek', 'sent']:
        path = directory / f'{name}-controls.json'
        if path.exists():
            labels = {control['label'] for control in json.loads(path.read_text())['controls']}
            print(f'{name}: +{sorted(labels - before)} -{sorted(before - labels)}')


if __name__ == '__main__':
    main()
