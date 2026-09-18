#!/usr/bin/env python3
"""Exercise semantic conversation rendering with a deterministic Codex app-server fixture."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from gui_multiplexer import Actions, exercise


RESPONSE = '''## A conversation you can follow

The conversation now separates **the answer**, tool activity, and delegated work.

### What changed

- Native messages with readable typography and `inline code`.
- Tool output stays one click away.
- Each subagent keeps its own status when dispatch finishes.

```zig
const pane = try workspace.createAgentTab();
try pane.submit("Review the changes");
```

> The runtime keeps the conversation alive when the window closes.
'''

FAKE_CODEX = r'''
import json
import os
from pathlib import Path
import sys
import threading
import time

root = Path(os.environ['FAKE_CODEX_DIRECTORY'])
(root / 'codex.pid').write_text(str(os.getpid()))
lock = threading.Lock()

def emit(value):
    with lock:
        print(json.dumps(value), flush=True)

def event(method, value):
    emit({'method': method, 'params': value})

def item(method, value, thread='thread-native', turn='turn-native'):
    event('item/' + method, {'threadId': thread, 'turnId': turn, 'item': value})

def gate(name):
    (root / (name + '-ready')).touch()
    deadline = time.monotonic() + 90
    while not (root / ('continue-' + name)).exists():
        if time.monotonic() > deadline:
            raise RuntimeError('Fixture timed out at ' + name)
        time.sleep(.02)

def turn():
    event('turn/started', {'threadId': 'thread-native', 'turn': {'id': 'turn-native', 'status': 'inProgress'}})
    item('started', {'id': 'reasoning', 'type': 'reasoning', 'summary': [], 'content': []})
    event('item/reasoning/summaryTextDelta', {'threadId': 'thread-native', 'turnId': 'turn-native', 'itemId': 'reasoning', 'summaryIndex': 0, 'delta': 'Reviewing the conversation layout and the runtime event contract.'})
    gate('thinking')
    item('completed', {'id': 'reasoning', 'type': 'reasoning', 'summary': ['Reviewing the conversation layout and the runtime event contract.'], 'content': []})
    for child, name, role in [('review', 'Review', 'explorer'), ('tests', 'Tests', 'worker')]:
        event('thread/started', {'thread': {'id': 'child-' + child, 'source': {'subAgent': {'thread_spawn': {
            'parent_thread_id': 'thread-native', 'depth': 1, 'agent_path': '/root/' + child,
            'agent_nickname': name, 'agent_role': role}}}}})
        item('started', {'id': 'dispatch-' + child, 'type': 'collabAgentToolCall', 'tool': 'spawnAgent',
            'status': 'inProgress', 'senderThreadId': 'thread-native', 'receiverThreadIds': ['child-' + child],
            'prompt': 'Review message rendering.' if child == 'review' else 'Check streaming, reconnect and tool statuses.',
            'model': 'fake-model', 'reasoningEffort': 'medium', 'agentsStates': {'child-' + child: {'status': 'running', 'message': None}}})
        item('completed', {'id': 'dispatch-' + child, 'type': 'collabAgentToolCall', 'tool': 'spawnAgent',
            'status': 'completed', 'senderThreadId': 'thread-native', 'receiverThreadIds': ['child-' + child],
            'prompt': 'Review message rendering.' if child == 'review' else 'Check streaming, reconnect and tool statuses.',
            'model': 'fake-model', 'reasoningEffort': 'medium', 'agentsStates': {'child-' + child: {'status': 'running', 'message': None}}})
        event('turn/started', {'threadId': 'child-' + child, 'turn': {'id': 'turn-' + child, 'status': 'inProgress'}})
    item('started', {'id': 'command', 'type': 'commandExecution', 'command': 'zig build check', 'cwd': '/project/telar',
        'status': 'inProgress', 'commandActions': [], 'aggregatedOutput': ''})
    event('item/commandExecution/outputDelta', {'threadId': 'thread-native', 'turnId': 'turn-native', 'itemId': 'command', 'delta': 'Checking client boundaries...\nCompiling native widgets...\n'})
    gate('working')
    item('completed', {'id': 'command', 'type': 'commandExecution', 'command': 'zig build check', 'cwd': '/project/telar',
        'status': 'completed', 'commandActions': [], 'aggregatedOutput': 'Client boundaries passed.\nNative widgets compiled.\nAll checks passed.', 'exitCode': 0, 'durationMs': 843})
    item('completed', {'id': 'mcp', 'type': 'mcpToolCall', 'server': 'docs', 'tool': 'search', 'status': 'failed',
        'arguments': {'query': 'app-server item lifecycle'}, 'result': None, 'error': {'message': 'The local documentation index is unavailable.'}})
    item('completed', {'id': 'files', 'type': 'fileChange', 'status': 'completed', 'changes': [{'path': 'src/gui/widgets/ThreadPane.zig',
        'kind': {'type': 'update', 'move_path': None}, 'diff': '@@ -1,2 +1,2 @@\n- drawPlainTranscript();\n+ drawConversation();'}]})
    for child, result in [('review', 'Reviewed message hierarchy, wrapping and tool details.'), ('tests', 'Streaming and reconnect checks passed. Child states remain independent.')]:
        item('completed', {'id': 'answer-' + child, 'type': 'agentMessage', 'phase': 'final_answer', 'text': result}, 'child-' + child, 'turn-' + child)
        event('turn/completed', {'threadId': 'child-' + child, 'turn': {'id': 'turn-' + child, 'status': 'completed'}})
    gate('tools')
    item('completed', {'id': 'answer', 'type': 'agentMessage', 'phase': 'final_answer', 'text': (root / 'response.txt').read_text()})
    event('turn/completed', {'threadId': 'thread-native', 'turn': {'id': 'turn-native', 'status': 'completed'}})
    (root / 'complete-ready').touch()

for line in sys.stdin:
    message = json.loads(line)
    with (root / 'provider.jsonl').open('a') as log:
        log.write(json.dumps(message) + '\n')
    method = message.get('method')
    if method == 'initialize':
        emit({'id': message['id'], 'result': {}})
    elif method == 'model/list':
        emit({'id': message['id'], 'result': {'data': [{
            'id': 'fake-model', 'model': 'fake-model', 'displayName': 'Codex fixture', 'isDefault': True,
            'supportedReasoningEfforts': [{'reasoningEffort': 'medium', 'description': 'Balanced'}],
            'defaultReasoningEffort': 'medium'}], 'nextCursor': None}})
    elif method == 'thread/start':
        emit({'id': message['id'], 'result': {'thread': {'id': 'thread-native'}, 'model': 'fake-model',
            'reasoningEffort': 'medium', 'approvalPolicy': 'untrusted', 'approvalsReviewer': 'user',
            'sandbox': {'type': 'workspaceWrite'}}})
        (root / 'provider-ready').touch()
    elif method == 'turn/start':
        emit({'id': message['id'], 'result': {'turn': {'id': 'turn-native'}}})
        threading.Thread(target=turn, daemon=True).start()
'''


def stage(actions, name):
    actions.items.append(dict(wait=str(actions.directory / (name + '-ready'))))
    actions.items.extend([{}, {}, {}])
    actions.capture(name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('directory', type=Path, help='new short /tmp directory')
    parser.add_argument('--driver-source', type=Path, default=Path(__file__).with_name('gui_actions.m'))
    parser.add_argument('--resize', type=int, nargs=2, metavar=('WIDTH', 'HEIGHT'))
    parser.add_argument('--response-file', type=Path)
    parser.add_argument('--diagrams', action='store_true', help='require real native diagram textures')
    args = parser.parse_args()
    binary, directory = args.binary.resolve(), args.directory.resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    response = args.response_file.read_text() if args.response_file else RESPONSE
    (directory / 'response.txt').write_text(response)
    fake = directory / 'codex'
    fake.write_text(f'#!{sys.executable}\n' + FAKE_CODEX)
    fake.chmod(0o700)
    library = directory / 'driver.dylib'
    subprocess.run(['clang', '-dynamiclib', '-fobjc-arc', '-I' + str(Path(__file__).parent), '-framework', 'AppKit',
                    str(args.driver_source), '-o', str(library)], check=True)
    env = {key: value for key, value in os.environ.items() if not key.startswith('TELAR_')}
    env.update(TELAR_SOCKET=str(directory / 'runtime.sock'), TELAR_HISTORY=str(directory / 'history.db'),
               FAKE_CODEX_DIRECTORY=str(directory), PATH=str(directory) + os.pathsep + env.get('PATH', ''))
    if args.diagrams:
        env['TELAR_GUI_MARKER'] = '254,253,252'
    subprocess.run([str(binary), 'server', '--background', '--no-config'], env=env, cwd=directory, check=True)
    try:
        actions = Actions(directory)
        if args.resize:
            actions.items.append(dict(resize=args.resize))
            actions.items.extend([{}] * 12)
        actions.prefix('a', 0)
        actions.items.append(dict(wait=str(directory / 'provider-ready')))
        actions.items.extend([{}, {}, {}])
        actions.items.append(dict(click_label='Message to agent'))
        actions.text('Make agent conversations clear, with visible tools and delegated work.')
        actions.key('\r', 36)
        stage(actions, 'thinking')
        actions.items.append(dict(signal=str(directory / 'continue-thinking')))
        stage(actions, 'working')
        actions.items.append(dict(click_label='Show agent work'))
        actions.items.extend([{}, {}, {}])
        actions.capture('work-expanded')
        actions.items.append(dict(click_label='Expand Review'))
        actions.items.extend([{}, {}, {}])
        actions.capture('subagent-detail')
        actions.items.append(dict(click_label='Collapse Review'))
        actions.items.extend([{}, {}, {}])
        actions.items.append(dict(signal=str(directory / 'continue-working')))
        stage(actions, 'tools')
        actions.items.append(dict(click_label='Expand Command'))
        actions.items.extend([{}, {}, {}])
        actions.capture('command-detail')
        actions.items.append(dict(click_label='Collapse Command'))
        actions.items.extend([{}, {}, {}])
        actions.items.append(dict(click_label='Expand File changes'))
        actions.items.extend([{}, {}, {}])
        actions.key('\uf72d', 121)
        actions.items.extend([{}, {}, {}])
        actions.capture('file-detail')
        actions.items.append(dict(click_label='Collapse File changes'))
        actions.items.extend([{}, {}, {}])
        actions.key('\uf72c', 116)
        actions.items.extend([{}, {}, {}])
        actions.items.append(dict(click_label='Hide agent work'))
        actions.items.extend([{}, {}, {}])
        actions.items.append(dict(signal=str(directory / 'continue-tools')))
        stage(actions, 'complete')
        if args.diagrams:
            actions.items.append(dict(wait_diagrams=1, wait_seconds=25))
            actions.items.extend([{}, {}, {}])
            actions.items.append(dict(record=str(directory / 'diagram-frame.json')))
            actions.capture('diagram-bottom')
        actions.items.append(dict(click_label='Copy response'))
        actions.items.extend([{}, {}, {}])
        actions.items.append(dict(expect_clipboard=response))
        if args.diagrams:
            for _ in range(3):
                actions.key('\uf72c', 116)
                actions.items.extend([{}, {}, {}])
            actions.capture('diagram-top')
            for _ in range(3):
                actions.key('\uf72d', 121)
                actions.items.extend([{}, {}, {}])
        if args.resize:
            actions.items.append(dict(resize=[660, 760]))
            actions.items.extend([{}, {}, {}])
            actions.capture('narrow')
        exercise(binary, directory, env, library, actions, 'messages')
        pid = int((directory / 'codex.pid').read_text())
        os.kill(pid, 0)
        reconnect = Actions(directory)
        if args.resize:
            reconnect.items.append(dict(resize=args.resize))
        reconnect.items.extend([{}] * 8)
        if args.diagrams:
            reconnect.items.append(dict(wait_diagrams=1, wait_seconds=25))
        reconnect.capture('reconnected')
        exercise(binary, directory, env, library, reconnect, 'reconnect')
        os.kill(pid, 0)
        requests = [json.loads(line) for line in (directory / 'provider.jsonl').read_text().splitlines()]
        assert sum(r.get('method') == 'initialize' for r in requests) == 1
        assert sum(r.get('method') == 'turn/start' for r in requests) == 1
        result = dict(fixture=True, semantic_tools_and_subagents=True, native_disclosure=True,
                      work_collapsed_by_default=True, native_work_disclosure=True,
                      native_copy_preserves_markdown=True, reconnect_reused_provider=True,
                      screenshots=sorted(p.name for p in directory.glob('*.png')))
        if args.diagrams:
            frame = json.loads((directory / 'diagram-frame.json').read_text())
            assert frame['diagrams'], 'No diagram texture was delivered to the native renderer'
            result['native_diagram_textures'] = frame['diagrams']
        (directory / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2))
    finally:
        subprocess.run([str(binary), 'server', 'stop'], env=env, stdout=subprocess.DEVNULL, timeout=10, check=False)


if __name__ == '__main__':
    main()
