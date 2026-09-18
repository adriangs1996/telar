#!/usr/bin/env python3
"""Verify GUI agent panes with a fake Codex, native input, and detach/reconnect."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time

from gui_multiplexer import Actions, exercise


FAKE_CODEX = r'''
import json
import os
from pathlib import Path
import sys
import threading
import time

directory = Path(os.environ['FAKE_CODEX_DIRECTORY'])
(directory / 'codex.pid').write_text(str(os.getpid()))
lock = threading.Lock()

def emit(value):
    with lock:
        print(json.dumps(value), flush=True)

def finish_detached():
    deadline = time.monotonic() + 20
    while not (directory / 'finish-detached').exists():
        if time.monotonic() > deadline:
            return
        time.sleep(.02)
    emit({'method': 'item/completed', 'params': {'threadId': 'thread-native', 'turnId': 'turn-native', 'item': {
        'id': 'assistant-native', 'type': 'agentMessage', 'text':
        """## Agent pane ready

Your request arrived through the native composer.

- The conversation belongs to the runtime.
- The GUI can close while work continues.
- Reconnecting restores the messages.

```zig
const pane = try workspace.createAgentTab();
try pane.submit("Build something useful");
```

Completed while the GUI was disconnected."""}}})
    emit({'method': 'turn/completed', 'params': {'threadId': 'thread-native', 'turn': {'id': 'turn-native', 'status': 'completed'}}})
    (directory / 'background-complete').touch()

for line in sys.stdin:
    message = json.loads(line)
    with (directory / 'provider.jsonl').open('a') as log:
        log.write(json.dumps(message) + '\n')
    method = message.get('method')
    if method == 'initialize':
        emit({'id': message['id'], 'result': {}})
    elif method == 'model/list':
        emit({'id': message['id'], 'result': {'data': [{
            'id': 'fake-model', 'model': 'fake-model', 'displayName': 'Fake Codex', 'isDefault': True,
            'supportedReasoningEfforts': [{'reasoningEffort': 'low', 'description': 'Fast'},
                                         {'reasoningEffort': 'max', 'description': 'Thorough'}],
            'defaultReasoningEffort': 'low'}], 'nextCursor': None}})
    elif method == 'thread/start':
        emit({'id': message['id'], 'result': {'thread': {'id': 'thread-native'},
            'model': 'fake-model', 'reasoningEffort': 'low', 'approvalPolicy': 'untrusted',
            'approvalsReviewer': 'user', 'sandbox': {'type': 'workspaceWrite'}}})
        (directory / 'provider-ready').touch()
    elif method == 'turn/start':
        (directory / 'received-prompt.json').write_text(json.dumps(message['params']['input']))
        emit({'id': message['id'], 'result': {'turn': {'id': 'turn-native'}}})
        emit({'method': 'item/started', 'params': {'threadId': 'thread-native', 'turnId': 'turn-native', 'item': {
            'id': 'command-native', 'type': 'commandExecution', 'command': 'zig build check', 'aggregatedOutput': ''}}})
        emit({'method': 'item/completed', 'params': {'threadId': 'thread-native', 'turnId': 'turn-native', 'item': {
            'id': 'command-native', 'type': 'commandExecution', 'command': 'zig build check', 'aggregatedOutput': 'All checks passed.'}}})
        for delta in ['## Agent pane ready\n\n', 'Your request arrived through the native composer.\n\n',
                      'I am continuing this turn in the runtime.']:
            emit({'method': 'item/agentMessage/delta', 'params': {'threadId': 'thread-native', 'turnId': 'turn-native', 'itemId': 'assistant-native', 'delta': delta}})
            time.sleep(.12)
        (directory / 'stream-visible').touch()
        threading.Thread(target=finish_detached, daemon=True).start()
'''


def wait_for(path, timeout=10):
    deadline = time.monotonic() + timeout
    while not path.exists():
        if time.monotonic() > deadline:
            raise RuntimeError(f'Timed out waiting for {path.name}')
        time.sleep(.02)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('directory', type=Path, help='new short /tmp directory')
    args = parser.parse_args()
    binary = args.binary.resolve()
    directory = args.directory.resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    fake = directory / 'codex'
    fake.write_text(f'#!{sys.executable}\n' + FAKE_CODEX)
    fake.chmod(0o700)
    library = directory / 'driver.dylib'
    subprocess.run(['clang', '-dynamiclib', '-fobjc-arc', '-framework', 'AppKit',
                    str(Path(__file__).with_name('gui_actions.m')), '-o', str(library)], check=True)
    env = {key: value for key, value in os.environ.items() if not key.startswith('TELAR_')}
    env.update(TELAR_SOCKET=str(directory / 'runtime.sock'), TELAR_HISTORY=str(directory / 'history.db'),
               FAKE_CODEX_DIRECTORY=str(directory), PATH=str(directory) + os.pathsep + env.get('PATH', ''))
    subprocess.run([str(binary), 'server', '--background', '--no-config'], env=env, cwd=directory, check=True)
    try:
        message = 'Build an agent pane with a native composer.\nKeep the conversation alive when I close the GUI.'
        first = Actions(directory)
        first.prefix('a', 0)
        first.items.append(dict(wait=str(directory / 'provider-ready')))
        first.items.extend([{}, {}, {}])
        first.items.append(dict(click_label='Message to agent'))
        first.text(message)
        first.items.append(dict(expect_value=dict(label='Message to agent', value=message)))
        first.key('\r', 36)
        first.items.append(dict(wait=str(directory / 'stream-visible')))
        first.items.extend([{}, {}, {}])
        first.items.append(dict(expect_value=dict(label='Message to agent', value='')))
        first.capture('streaming')
        exercise(binary, directory, env, library, first, 'first')

        pid = int((directory / 'codex.pid').read_text())
        os.kill(pid, 0)
        received = json.loads((directory / 'received-prompt.json').read_text())
        assert received == [dict(type='text', text=message)], received
        detached_agents = json.loads(subprocess.check_output([str(binary), 'agent', 'list', '--json'], env=env))
        assert len(detached_agents['agents']) == 1, detached_agents
        (directory / 'finish-detached').touch()
        wait_for(directory / 'background-complete')
        os.kill(pid, 0)

        reconnect = Actions(directory)
        reconnect.items.extend([{}, {}, {}])
        reconnect.items.append(dict(click_label='Message to agent'))
        reconnect.items.append(dict(expect_value=dict(label='Message to agent', value='')))
        reconnect.capture('reconnected')
        exercise(binary, directory, env, library, reconnect, 'reconnect')
        os.kill(pid, 0)
        requests = [json.loads(line) for line in (directory / 'provider.jsonl').read_text().splitlines()]
        assert sum(request.get('method') == 'initialize' for request in requests) == 1, requests
        assert sum(request.get('method') == 'thread/start' for request in requests) == 1, requests
        assert sum(request.get('method') == 'turn/start' for request in requests) == 1, requests
        for name in ['streaming.png', 'reconnected.png']:
            assert (directory / name).stat().st_size > 0, name
        result = dict(prefix_a_created_agent=True, multiline_composer_submitted=True,
                      provider_survived_gui_close=True, completed_while_detached=True,
                      reconnect_reused_provider=True, provider_pid=pid,
                      agents_while_detached=detached_agents,
                      screenshots=['streaming.png', 'reconnected.png'])
        (directory / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2))
    finally:
        subprocess.run([str(binary), 'server', 'stop'], env=env,
                       stdout=subprocess.DEVNULL, timeout=10, check=False)


if __name__ == '__main__':
    main()
