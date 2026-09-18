#!/usr/bin/env python3
"""Exercise native slash commands and skill completion without model calls."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from gui_multiplexer import Actions, exercise

PROVIDER = r'''
import json
import os
from pathlib import Path
import sys

root = Path(os.environ['FAKE_CODEX_DIRECTORY'])
thread = 0

def emit(value):
    print(json.dumps(value), flush=True)

for line in sys.stdin:
    message = json.loads(line)
    with (root / 'provider.jsonl').open('a') as log:
        log.write(json.dumps(message) + '\n')
    method = message.get('method')
    result = {}
    if method == 'initialize':
        pass
    elif method == 'model/list':
        result = {'data': [{'model': 'fake-model', 'displayName': 'Fake Codex',
            'supportedReasoningEfforts': [{'reasoningEffort': 'low'}],
            'defaultReasoningEffort': 'low'}], 'nextCursor': None}
    elif method == 'skills/list':
        result = {'data': [{'cwd': str(root), 'errors': [], 'skills': [
            {'name': 'review', 'description': 'Review the current changes', 'enabled': True,
             'path': '/skills/review/SKILL.md', 'scope': 'user', 'interface': {'displayName': 'Code Review'}},
            {'name': 'release', 'description': 'Prepare the next release', 'enabled': True,
             'path': '/skills/release/SKILL.md', 'scope': 'repo'},
            {'name': 'diagram', 'description': 'Draw an architecture diagram', 'enabled': True,
             'path': '/skills/diagram/SKILL.md', 'scope': 'system', 'pluginId': 'diagrams'}]}]}
        (root / 'skills-ready').touch()
    elif method == 'thread/list':
        result = {'data': [], 'nextCursor': None}
    elif method == 'thread/start':
        thread += 1
        result = {'thread': {'id': f'thread-{thread}', 'cwd': str(root)}, 'model': 'fake-model',
            'reasoningEffort': 'low', 'approvalPolicy': 'untrusted', 'approvalsReviewer': 'user',
            'sandbox': {'type': 'workspaceWrite'}}
        if thread == 2:
            (root / 'cleared').touch()
    elif method == 'thread/name/set':
        (root / 'renamed').write_text(message['params']['name'])
    elif method == 'turn/start':
        emit({'id': message['id'], 'result': {'turn': {'id': 'turn-1'}}})
        emit({'method': 'turn/completed', 'params': {'threadId': message['params']['threadId'],
            'turn': {'id': 'turn-1', 'status': 'completed'}}})
        (root / 'prompt-received').touch()
        continue
    else:
        continue
    emit({'id': message['id'], 'result': result})
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    binary, directory = args.binary.resolve(), args.directory.resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    fake = directory / 'codex'
    fake.write_text(f'#!{sys.executable}\n' + PROVIDER)
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
        actions.items.append(dict(resize=[1100, 800]))
        actions.items.extend([{}] * 6)
        actions.prefix('a', 0)
        actions.items.append(dict(wait=str(directory / 'skills-ready')))
        actions.items.extend([{}] * 5)
        actions.items.append(dict(click_label='Message to agent'))
        actions.text('/')
        actions.items.extend([{}] * 3)
        actions.capture('commands')
        actions.items.append(dict(click_label='/rename'))
        actions.text('Selector verification')
        actions.items.append(dict(click_label='Send message'))
        actions.items.append(dict(wait=str(directory / 'renamed')))
        actions.items.extend([{}] * 3)
        actions.items.append(dict(click_label='Message to agent'))
        actions.text('/clear')
        actions.items.append(dict(click_label='Send message'))
        actions.items.append(dict(wait=str(directory / 'cleared')))
        actions.items.extend([{}] * 4)
        actions.items.append(dict(click_label='Message to agent'))
        actions.text('$')
        actions.items.extend([{}] * 3)
        actions.capture('skills')
        actions.text('rev')
        actions.items.extend([{}] * 2)
        actions.capture('filtered-skills')
        actions.items.append(dict(click_label='Code Review'))
        actions.items.append(dict(expect_value=dict(label='Message to agent', value='$review ')))
        actions.text('Inspect the current changes.')
        actions.items.append(dict(click_label='Send message'))
        actions.items.append(dict(wait=str(directory / 'prompt-received')))
        exercise(binary, directory, env, library, actions, 'completions')
        requests = [json.loads(line) for line in (directory / 'provider.jsonl').read_text().splitlines()]
        turns = [message for message in requests if message.get('method') == 'turn/start']
        assert len(turns) == 1, turns
        assert turns[0]['params']['threadId'] == 'thread-2'
        assert turns[0]['params']['input'] == [
            {'type': 'text', 'text': '$review Inspect the current changes.'},
            {'type': 'skill', 'name': 'review', 'path': '/skills/review/SKILL.md'}]
        assert (directory / 'renamed').read_text() == 'Selector verification'
        result = dict(command_picker=True, skill_picker=True, skill_filter=True,
                      renamed=True, cleared=True, explicit_skill_input=True)
        (directory / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2))
    finally:
        subprocess.run([str(binary), 'server', 'stop'], env=env,
                       stdout=subprocess.DEVNULL, timeout=10, check=False)


if __name__ == '__main__':
    main()
