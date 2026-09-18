#!/usr/bin/env python3
"""Exercise recent conversation selection, history and continuation without model calls."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from gui_agent_lifecycle import FAKE_CODEX
from gui_multiplexer import Actions, exercise


RESUME_METHODS = r'''
    elif method == 'thread/list':
        emit({'id': message['id'], 'result': {'data': [
            {'id': 'thread-native', 'name': 'Continue parser work', 'cwd': str(directory)},
            {'id': 'another-thread', 'name': 'Review input routing', 'cwd': str(directory)}
        ], 'nextCursor': None}})
        (directory / 'recent-ready').touch()
    elif method == 'thread/resume':
        assert message['params']['threadId'] == 'thread-native'
        emit({'id': message['id'], 'result': {
            'thread': {'id': 'thread-native', 'name': 'Continue parser work', 'cwd': str(directory)},
            'model': 'fake-model', 'reasoningEffort': 'low', 'approvalPolicy': 'untrusted',
            'approvalsReviewer': 'user', 'sandbox': {'type': 'workspaceWrite'}}})
        (directory / 'resumed').touch()
    elif method == 'thread/read':
        emit({'id': message['id'], 'result': {'thread': {
            'id': 'thread-native', 'historyMode': 'paginated'}}})
    elif method == 'thread/items/list':
        emit({'id': message['id'], 'result': {'data': [{'turnId': 'old-turn', 'item': {
            'id': 'old-answer', 'type': 'agentMessage', 'text':
            'The parser now handles partial frames. Next, add the regression tests.'}}],
            'nextCursor': None, 'backwardsCursor': 'old-answer'}})
        (directory / 'history-read').touch()
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    binary, directory = args.binary.resolve(), args.directory.resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    source = FAKE_CODEX.replace("{'id': 'thread-native'},", "{'id': 'new-native'},")
    source = source.replace("    elif method == 'turn/start':", RESUME_METHODS + "    elif method == 'turn/start':")
    fake = directory / 'codex'
    fake.write_text(f'#!{sys.executable}\n' + source)
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
        actions.items.extend([{}] * 8)
        actions.capture('initial-window')
        actions.prefix('a', 0)
        actions.items.append(dict(wait=str(directory / 'recent-ready')))
        actions.items.extend([{}] * 5)
        actions.items.append(dict(click_label='Message to agent'))
        actions.text('Add the regression tests we discussed.')
        actions.items.append(dict(click_label='Resume conversation'))
        actions.items.extend([{}] * 3)
        actions.capture('recent-conversations')
        actions.items.append(dict(click_label='Continue parser work'))
        actions.items.append(dict(wait=str(directory / 'history-read')))
        actions.items.extend([{}] * 6)
        actions.items.append(dict(expect_value=dict(label='Message to agent', value='Add the regression tests we discussed.')))
        actions.capture('resumed-conversation')
        actions.items.append(dict(click_label='Message to agent'))
        actions.items.append(dict(click_label='Send message'))
        actions.items.extend([{}] * 3)
        actions.capture('after-submit')
        actions.items.append(dict(wait=str(directory / 'stream-visible')))
        actions.items.extend([{}] * 3)
        actions.capture('continued-conversation')
        exercise(binary, directory, env, library, actions, 'resume')
        reconnect = Actions(directory)
        reconnect.items.extend([{}] * 6)
        reconnect.capture('reconnected-conversation')
        exercise(binary, directory, env, library, reconnect, 'reconnect')
        requests = [json.loads(line) for line in (directory / 'provider.jsonl').read_text().splitlines()]
        resumes = [item for item in requests if item.get('method') == 'thread/resume']
        turns = [item for item in requests if item.get('method') == 'turn/start']
        assert len(resumes) == 1 and resumes[0]['params']['threadId'] == 'thread-native'
        assert len(turns) == 1 and turns[0]['params']['threadId'] == 'thread-native'
        assert sum(item.get('method') == 'thread/start' for item in requests) == 1
        result = dict(resumed_existing_thread=True, loaded_history=True, preserved_draft=True,
                      continued_same_thread=True, reconnect_reused_provider=True)
        (directory / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2))
    finally:
        subprocess.run([str(binary), 'server', 'stop'], env=env,
                       stdout=subprocess.DEVNULL, timeout=10, check=False)


if __name__ == '__main__':
    main()
