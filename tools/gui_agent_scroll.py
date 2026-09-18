#!/usr/bin/env python3
"""Exercise folded history pagination and disclosure reload in a real macOS window."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from gui_agent_messages import FAKE_CODEX
from gui_agent_lifecycle import wait_for
from gui_multiplexer import Actions, exercise


PROMPT = 'Find the previous visible message without scrolling through hidden tool output.'
ANSWER = 'The work is complete. This response must stay visible while hidden history loads.'
HISTORY = r'''
entries = [{'id': 'prompt', 'type': 'userMessage', 'content': [
    {'type': 'text', 'text': (root / 'prompt.txt').read_text()}]}]
for number in range(24):
    entries.append({'id': 'command-' + str(number), 'type': 'commandExecution',
        'command': 'check-part ' + str(number), 'cwd': '/project/telar',
        'status': 'completed', 'commandActions': [], 'exitCode': 0,
        'aggregatedOutput': ('Completed hidden activity %02d.\n' % number) * 400})
entries.append({'id': 'answer', 'type': 'agentMessage', 'phase': 'final_answer',
    'text': (root / 'answer.txt').read_text()})

def turn():
    event('turn/started', {'threadId': 'thread-native', 'turn': {'id': 'turn-native', 'status': 'inProgress'}})
    for entry in entries[1:]:
        item('completed', entry)
    event('turn/completed', {'threadId': 'thread-native', 'turn': {'id': 'turn-native', 'status': 'completed'}})
    (root / 'complete-ready').touch()

'''
METHODS = r'''
    elif method == 'thread/read':
        emit({'id': message['id'], 'result': {'thread': {
            'id': 'thread-native', 'historyMode': 'paginated'}}})
    elif method == 'thread/items/list':
        params = message['params']
        older = params['sortDirection'] == 'desc'
        cursor = params.get('cursor')
        number = int(cursor.split('-')[1]) if cursor else (len(entries) - 1 if older else 0)
        following = number - 1 if older else number + 1
        if number == 0:
            (root / 'prompt-reached').touch()
            if (root / 'reload-enabled').exists():
                (root / 'prompt-recovered').touch()
        if (root / 'reload-enabled').exists():
            (root / 'reload-read').touch()
        emit({'id': message['id'], 'result': {
            'data': [{'turnId': 'turn-native', 'item': entries[number]}],
            'nextCursor': 'position-' + str(following) if 0 <= following < len(entries) else None,
            'backwardsCursor': 'position-' + str(number)}})
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('directory', type=Path, help='new short /tmp directory')
    args = parser.parse_args()
    binary, directory = args.binary.resolve(), args.directory.resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    (directory / 'prompt.txt').write_text(PROMPT)
    (directory / 'answer.txt').write_text(ANSWER)
    source = FAKE_CODEX[:FAKE_CODEX.index('def turn():')] + HISTORY + FAKE_CODEX[FAKE_CODEX.index('for line in sys.stdin:'):]
    source = source.replace("    elif method == 'turn/start':", METHODS + "    elif method == 'turn/start':")
    fake = directory / 'codex'
    fake.write_text(f'#!{sys.executable}\n' + source)
    fake.chmod(0o700)
    library = directory / 'driver.dylib'
    subprocess.run(['clang', '-dynamiclib', '-fobjc-arc', '-framework', 'AppKit',
                    str(Path(__file__).with_name('gui_actions.m')), '-o', str(library)], check=True)
    env = {key: value for key, value in os.environ.items() if not key.startswith('TELAR_')}
    env.update(TELAR_SOCKET=str(directory / 'runtime.sock'), TELAR_HISTORY=str(directory / 'history.db'),
               FAKE_CODEX_DIRECTORY=str(directory), PATH=str(directory) + os.pathsep + env.get('PATH', ''))
    runtime_log = (directory / 'runtime.log').open('w')
    runtime = subprocess.Popen([str(binary), 'server', '--no-config'], env=env, cwd=directory,
                               stdout=runtime_log, stderr=runtime_log)
    try:
        wait_for(directory / 'runtime.sock')
        actions = Actions(directory)
        actions.items.append(dict(resize=[1100, 800]))
        actions.items.extend([{}] * 8)
        actions.prefix('a', 0)
        actions.items.append(dict(wait=str(directory / 'provider-ready')))
        actions.items.extend([{}] * 3)
        actions.items.append(dict(click_label='Message to agent'))
        actions.text(PROMPT)
        actions.key('\r', 36)
        actions.items.append(dict(wait=str(directory / 'complete-ready')))
        actions.items.extend([{}] * 8)
        actions.capture('before-scroll')
        actions.key('\uf72c', 116)
        actions.items.append(dict(wait=str(directory / 'prompt-reached'), wait_seconds=30))
        actions.items.extend([{}] * 8)
        actions.capture('after-one-scroll')
        actions.items.append(dict(click_label='Copy response'))
        actions.items.extend([{}] * 3)
        actions.items.append(dict(expect_clipboard=ANSWER))
        actions.items.append(dict(signal=str(directory / 'reload-enabled')))
        actions.items.append(dict(click_label='Show agent work'))
        actions.items.append(dict(wait=str(directory / 'reload-read')))
        actions.items.extend([{}] * 8)
        actions.capture('expanded-work')
        actions.items.append(dict(click_label='Hide agent work'))
        actions.items.append(dict(wait=str(directory / 'prompt-recovered'), wait_seconds=30))
        actions.items.extend([{}] * 8)
        actions.capture('collapsed-again')
        exercise(binary, directory, env, library, actions, 'folded-history')
        requests = [json.loads(line) for line in (directory / 'provider.jsonl').read_text().splitlines()]
        reads = [entry for entry in requests if entry.get('method') == 'thread/items/list']
        assert len(reads) > 24, 'Expected multiple bounded pages and reloading after expansion'
        print(json.dumps(dict(one_scroll_reached_prompt=True, expansion_reloaded_work=True,
                              provider_item_reads=len(reads)), indent=2))
    finally:
        subprocess.run([str(binary), 'server', 'stop'], env=env,
                       stdout=subprocess.DEVNULL, timeout=10, check=False)
        runtime.wait(timeout=10)
        runtime_log.close()


if __name__ == '__main__':
    main()
