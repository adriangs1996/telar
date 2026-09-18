#!/usr/bin/env python3
"""Validate the native composer against installed Codex with one real, read-only turn.

Requires an authenticated Codex CLI and macOS. This calls a model. The forwarding
wrapper records protocol metadata, never account/authentication responses.
"""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

from gui_multiplexer import Actions, exercise


FORWARDER = r'''
import json
import os
from pathlib import Path
import subprocess
import sys
import threading

directory = Path(os.environ['CODEX_PROBE_DIRECTORY'])
child = subprocess.Popen([os.environ['CODEX_PROBE_BINARY'], *sys.argv[1:]],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE)
(directory / 'codex.pid').write_text(str(child.pid))
methods = {}
sent = []
tools = []
output = []

def save(name, value):
    pending = directory / (name + '.pending')
    pending.write_text(json.dumps(value, indent=2) + '\n')
    pending.replace(directory / name)

def forward_input():
    try:
        for line in sys.stdin.buffer:
            message = json.loads(line)
            method = message.get('method')
            if method:
                sent.append(method)
                if 'id' in message:
                    methods[message['id']] = method
                if method == 'turn/start':
                    save('submitted.json', message['params'])
            child.stdin.write(line)
            child.stdin.flush()
    finally:
        child.stdin.close()

threading.Thread(target=forward_input, daemon=True).start()
try:
    for line in child.stdout:
        sys.stdout.buffer.write(line)
        sys.stdout.buffer.flush()
        message = json.loads(line)
        request = methods.get(message.get('id'))
        result = message.get('result', {})
        method = message.get('method')
        params = message.get('params', {})
        if request == 'model/list' and result:
            save('catalog.json', result['data'])
        elif request == 'thread/start' and result:
            save('thread.json', {key: result.get(key) for key in
                ['model', 'reasoningEffort', 'approvalPolicy', 'approvalsReviewer', 'sandbox']})
        elif method == 'item/completed':
            item = params.get('item', {})
            if item.get('type') == 'agentMessage':
                output.append(item.get('text', ''))
            elif item.get('type') not in ['userMessage', 'reasoning']:
                tools.append(item.get('type'))
        elif method == 'turn/completed':
            save('completed.json', dict(status=params['turn']['status'], output='\n'.join(output),
                                        tool_items=tools, methods_sent=sent))
finally:
    if child.poll() is None:
        child.terminate()
    child.wait(timeout=10)
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('directory', type=Path, help='new short /tmp directory')
    parser.add_argument('--codex', type=Path, help='Codex executable; defaults to codex on PATH')
    args = parser.parse_args()
    binary = args.binary.resolve()
    codex = str(args.codex.resolve()) if args.codex else shutil.which('codex')
    if not codex:
        parser.error('An installed and authenticated Codex CLI is required')
    version = subprocess.check_output([codex, '--version'], text=True).strip()
    directory = args.directory.resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    wrapper = directory / 'codex'
    wrapper.write_text(f'#!{sys.executable}\n' + FORWARDER)
    wrapper.chmod(0o700)
    library = directory / 'driver.dylib'
    subprocess.run(['clang', '-dynamiclib', '-fobjc-arc', '-framework', 'AppKit',
                    str(Path(__file__).with_name('gui_actions.m')), '-o', str(library)], check=True)
    env = {key: value for key, value in os.environ.items() if not key.startswith('TELAR_')}
    env.update(TELAR_SOCKET=str(directory / 'runtime.sock'), TELAR_HISTORY=str(directory / 'history.db'),
               CODEX_PROBE_DIRECTORY=str(directory), CODEX_PROBE_BINARY=codex,
               PATH=str(directory) + os.pathsep + env.get('PATH', ''))
    subprocess.run([str(binary), 'server', '--background', '--no-config'], env=env, cwd=directory, check=True)
    result = None
    try:
        initial = Actions(directory)
        initial.prefix('a', 0)
        for name in ['catalog.json', 'thread.json']:
            initial.items.append(dict(wait=str(directory / name), wait_seconds=45))
        initial.items.extend([{}, {}, {}])
        initial.capture('composer')
        initial.items.append(dict(click_label='Choose model'))
        initial.capture('models')
        initial.key('\x1b', 53)
        exercise(binary, directory, env, library, initial, 'initial')

        catalog = json.loads((directory / 'catalog.json').read_text())
        effective = json.loads((directory / 'thread.json').read_text())
        candidates = [model for model in catalog if not model.get('hidden') and
                      any(effort['reasoningEffort'] == 'low' for effort in model['supportedReasoningEfforts'])]
        assert candidates, 'The live catalog must include a model supporting low effort'
        model = next((candidate for candidate in candidates if not candidate.get('isDefault') and
                      candidate['model'] != effective['model']), candidates[0])
        prompt = ('Validate this native composer connection.\n'
                  'Reply exactly TELAR_GUI_CODEX_OK. Do not use tools, read files, or make changes.')
        turn = Actions(directory)
        turn.items.extend([{}, {}, {}])
        for selector, choice in [('Choose model', model['displayName']),
                                 ('Choose reasoning effort', 'Low'), ('Choose permissions', 'Read only')]:
            turn.items.append(dict(click_label=selector))
            turn.items.append(dict(click_label=choice))
        turn.items.append(dict(click_label='Message to agent'))
        turn.text(prompt)
        turn.items.append(dict(expect_value=dict(label='Message to agent', value=prompt)))
        turn.capture('draft')
        turn.items.append(dict(click_label='Send message'))
        turn.items.append(dict(wait=str(directory / 'completed.json'), wait_seconds=60))
        turn.items.extend([{}, {}, {}, {}])
        turn.items.append(dict(expect_value=dict(label='Message to agent', value='')))
        turn.capture('completed')
        exercise(binary, directory, env, library, turn, 'turn')

        submitted = json.loads((directory / 'submitted.json').read_text())
        completed = json.loads((directory / 'completed.json').read_text())
        assert submitted['input'] == [dict(type='text', text=prompt)], submitted['input']
        assert submitted['model'] == model['model'], submitted['model']
        assert submitted['effort'] == 'low', submitted['effort']
        assert submitted['approvalPolicy'] == 'untrusted', submitted['approvalPolicy']
        assert submitted['approvalsReviewer'] == 'user', submitted['approvalsReviewer']
        assert submitted['sandboxPolicy']['type'] == 'readOnly', submitted['sandboxPolicy']
        assert completed['status'] == 'completed', completed
        assert completed['output'].strip() == 'TELAR_GUI_CODEX_OK', completed
        assert completed['tool_items'] == [], completed
        for method in ['initialize', 'model/list', 'thread/start', 'turn/start']:
            assert completed['methods_sent'].count(method) == 1, completed['methods_sent']
        pid = int((directory / 'codex.pid').read_text())
        os.kill(pid, 0)
        result = dict(success=True, transport='native GUI -> IPC -> runtime Session -> codex app-server',
                      codex_version=version, codex_binary=codex,
                      catalog_models=len(catalog), selected_model=submitted['model'], selected_effort='low',
                      selected_access='read_only', response=completed['output'], tool_items=[],
                      reconnect_reused_provider=True, provider_pid=pid,
                      screenshots=['composer.png', 'models.png', 'draft.png', 'completed.png'])
    finally:
        subprocess.run([str(binary), 'server', 'stop'], env=env,
                       stdout=subprocess.DEVNULL, timeout=10, check=False)
    if result:
        deadline = time.monotonic() + 10
        while True:
            try:
                os.kill(result['provider_pid'], 0)
            except ProcessLookupError:
                break
            assert time.monotonic() < deadline, 'Provider survived isolated runtime shutdown'
            time.sleep(.05)
        result['provider_reaped'] = True
        (directory / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
