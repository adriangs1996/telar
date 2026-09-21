#!/usr/bin/env python3
"""Verify one native review action per pane with editions, using a fake provider."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from gui_agent_messages import FAKE_CODEX
from gui_multiplexer import Actions, exercise


TURN = '''def turn():
    event('turn/started', {'threadId': 'thread-native', 'turn': {'id': 'turn-native', 'status': 'inProgress'}})
    (root / 'sample.py').write_text('value = 2\\n')
    item('completed', {'id': 'edit', 'type': 'fileChange', 'status': 'completed', 'changes': [{
        'path': str(root / 'sample.py'), 'kind': {'type': 'update', 'move_path': None},
        'diff': '@@ -1 +1 @@\\n-value = 1\\n+value = 2\\n'}]})
    item('completed', {'id': 'answer', 'type': 'agentMessage', 'phase': 'final_answer',
        'text': 'Updated sample.py. The two ordinary terminal panes have no edits.'})
    event('turn/completed', {'threadId': 'thread-native', 'turn': {'id': 'turn-native', 'status': 'completed'}})
    (root / 'complete-ready').touch()

'''


def record(actions, name):
    actions.items.extend([{}] * 6)
    actions.items.append(dict(record=str(actions.directory / f'{name}.json')))
    actions.capture(name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('directory', type=Path, help='new short /tmp directory')
    args = parser.parse_args()
    binary, directory = args.binary.resolve(), args.directory.resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    (directory / 'sample.py').write_text('value = 1\n')
    fixture = FAKE_CODEX[:FAKE_CODEX.index('def turn():')] + TURN + FAKE_CODEX[FAKE_CODEX.index('for line in sys.stdin:'):]
    fake = directory / 'codex'
    fake.write_text(f'#!{sys.executable}\n' + fixture)
    fake.chmod(0o700)
    library = directory / 'driver.dylib'
    subprocess.run(['clang', '-dynamiclib', '-fobjc-arc', '-framework', 'AppKit',
                    str(Path(__file__).with_name('gui_actions.m')), '-o', str(library)], check=True)
    env = {key: value for key, value in os.environ.items() if not key.startswith('TELAR_')}
    env.update(TELAR_SOCKET=str(directory / 'runtime.sock'), TELAR_HISTORY=str(directory / 'history.db'),
               FAKE_CODEX_DIRECTORY=str(directory), PATH=str(directory) + os.pathsep + env.get('PATH', ''))
    subprocess.run([str(binary), 'server', '--background', '--no-config'], env=env, cwd=directory, check=True)
    try:
        actions = Actions(directory)
        actions.items.append(dict(resize=[1400, 900]))
        actions.items.extend([{}] * 12)
        record(actions, 'empty-terminal')
        actions.prefix('a', 0)
        actions.items.append(dict(wait=str(directory / 'provider-ready')))
        record(actions, 'empty-agent')
        actions.items.append(dict(click_label='Message to agent'))
        actions.text('Change sample.py.')
        actions.key('\r', 36)
        actions.items.append(dict(wait=str(directory / 'complete-ready'), wait_label='Review changes'))
        record(actions, 'single-agent')
        actions.prefix('%', 22, shift=True)
        actions.prefix('"', 39, shift=True)
        actions.prefix('\uf702', 123)
        record(actions, 'three-panes')
        actions.prefix('z', 6)
        record(actions, 'fullscreen-agent')
        actions.prefix('\uf703', 124)
        record(actions, 'fullscreen-terminal')
        actions.prefix('\uf702', 123)
        actions.prefix('z', 6)
        record(actions, 'restored')
        exercise(binary, directory, env, library, actions, 'availability')

        reconnect = Actions(directory)
        reconnect.items.append(dict(resize=[1400, 900], wait_label='Review changes'))
        record(reconnect, 'reconnected')
        exercise(binary, directory, env, library, reconnect, 'reconnect')

        expected = {'empty-terminal': 0, 'empty-agent': 0, 'single-agent': 1, 'three-panes': 1,
                    'fullscreen-agent': 1, 'fullscreen-terminal': 0, 'restored': 1, 'reconnected': 1}
        counts = {}
        for name, count in expected.items():
            controls = json.loads((directory / f'{name}.json').read_text())['controls']
            counts[name] = sum(control['label'] == 'Review changes' for control in controls)
            assert counts[name] == count, (name, counts[name], count)
        requests = [json.loads(line) for line in (directory / 'provider.jsonl').read_text().splitlines()]
        assert sum(request.get('method') == 'turn/start' for request in requests) == 1
        result = dict(fake_provider=True, model_calls=0, review_action_counts=counts,
                      screenshots=sorted(path.name for path in directory.glob('*.png')))
        (directory / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2))
    finally:
        subprocess.run([str(binary), 'server', 'stop'], env=env, stdout=subprocess.DEVNULL,
                       timeout=10, check=False)


if __name__ == '__main__':
    main()
