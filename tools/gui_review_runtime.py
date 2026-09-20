#!/usr/bin/env python3
"""Validate native change review through the production runtime and real Codex.

Runs two model turns in a new private workspace and closes all owned windows and
processes. Records only review evidence and protocol metadata, never credentials.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

from gui_multiplexer import Actions
import perf_e2e
from review_live import BASE_SOURCE, INITIAL_PROMPT
from gui_review_live import FEEDBACK


FORWARDER = r'''
import json
import os
from pathlib import Path
import subprocess
import sys
import threading

directory = Path(os.environ['CODEX_PROBE_DIRECTORY'])
child = subprocess.Popen([os.environ['CODEX_PROBE_BINARY'], *sys.argv[1:]], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
(directory / 'codex.pid').write_text(str(child.pid))
requests = {}
turns = 0
submitted = 0
evidence = []

def save(name, value):
    pending = directory / (name + '.pending')
    pending.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    pending.replace(directory / name)

def forward_input():
    global submitted
    try:
        for line in sys.stdin.buffer:
            value = json.loads(line)
            method = value.get('method')
            if method and 'id' in value:
                requests[value['id']] = method
            if method == 'turn/start':
                submitted += 1
                save(f'request-{submitted}.json', value['params'])
            child.stdin.write(line)
            child.stdin.flush()
    finally:
        child.stdin.close()

threading.Thread(target=forward_input, daemon=True).start()
try:
    for line in child.stdout:
        sys.stdout.buffer.write(line)
        sys.stdout.buffer.flush()
        value = json.loads(line)
        method = value.get('method')
        result = value.get('result', {})
        params = value.get('params', {})
        if requests.get(value.get('id')) == 'thread/start' and result:
            save('thread.json', dict(id=result['thread']['id'], model=result.get('model')))
        elif requests.get(value.get('id')) == 'model/list' and result:
            save('models-ready.json', dict(ready=True))
        elif method == 'item/completed':
            item = params.get('item', {})
            if item.get('type') == 'fileChange':
                evidence.append(dict(turn=params.get('turnId'), item=item))
        elif method == 'turn/completed':
            turns += 1
            save(f'turn-{turns}.json', dict(thread=params.get('threadId'), turn=params['turn'], patches=evidence))
            evidence = []
finally:
    if child.poll() is None:
        child.terminate()
    child.wait(timeout=10)
'''


def native(binary, directory, env, library, actions, name, checks=None):
    script = directory / f'{name}.actions.json'
    script.write_text(json.dumps(actions.items))
    with (directory / f'{name}.log').open('w') as log:
        process = subprocess.Popen([str(binary), 'gui', '--no-config', '/bin/sh'], cwd=directory,
                                   env=dict(env, DYLD_INSERT_LIBRARIES=str(library), TELAR_GUI_ACTIONS=str(script)),
                                   stdout=log, stderr=log)
        deadline = time.monotonic() + 210
        try:
            while process.poll() is None:
                for marker, check in (checks or {}).items():
                    destination = directory / marker
                    if not destination.exists() and check():
                        destination.write_text('ready\n')
                if time.monotonic() >= deadline:
                    raise TimeoutError(f'Native review phase {name} timed out')
                time.sleep(.05)
            if process.returncode:
                raise subprocess.CalledProcessError(process.returncode, process.args)
        finally:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=10)


def show(binary, env, pane, edition=None):
    args = [str(binary), 'review', 'show', str(pane), '--json']
    if edition is not None:
        args.extend(['--edition', str(edition)])
    return json.loads(subprocess.check_output(args, env=env, text=True, timeout=15))


def wait_review(binary, env, pane):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        result = show(binary, env, pane)
        if result['edition_id']:
            return result
        time.sleep(.1)
    raise AssertionError('The runtime did not retain the provider patch')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--codex', type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    codex = str(args.codex.resolve()) if args.codex else shutil.which('codex')
    if not codex:
        parser.error('An authenticated Codex CLI is required')
    directory = args.directory.resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    (directory / 'slug.py').write_text(BASE_SOURCE)
    wrapper = directory / 'codex'
    wrapper.write_text(f'#!{sys.executable}\n' + FORWARDER)
    wrapper.chmod(0o700)
    library = directory / 'driver.dylib'
    subprocess.run(['clang', '-dynamiclib', '-fobjc-arc', '-framework', 'AppKit',
                    str(Path(__file__).with_name('gui_actions.m')), '-o', str(library)], check=True)
    env = {key: value for key, value in os.environ.items() if not key.startswith('TELAR_')}
    env.update(TELAR_SOCKET=str(directory / 'runtime.sock'), TELAR_SOCKET_PATH=str(directory / 'runtime.sock'), TELAR_HISTORY=str(directory / 'history.db'),
               CODEX_PROBE_DIRECTORY=str(directory), CODEX_PROBE_BINARY=codex,
               PATH=str(directory) + os.pathsep + env.get('PATH', ''))
    subprocess.run([str(binary), 'server', '--background', '--no-config'], cwd=directory, env=env, check=True)
    try:
        edit = Actions(directory)
        edit.prefix('a')
        edit.items.append(dict(wait=str(directory / 'thread.json'), wait_seconds=45))
        edit.items.append(dict(wait=str(directory / 'models-ready.json'), wait_seconds=45))
        edit.items.extend([{}, {}, {}])
        for selector, choice in [('Choose permissions', 'Workspace'), ('Choose reasoning effort', 'Low')]:
            edit.items.extend([dict(click_label=selector), dict(wait_label=choice, wait_seconds=20, retry_label=selector), dict(click_label=choice), {}, {}])
        edit.items.append(dict(click_label='Message to agent'))
        edit.text(INITIAL_PROMPT)
        edit.items.append(dict(click_label='Send message'))
        edit.items.append(dict(wait=str(directory / 'turn-1.json'), wait_seconds=120, approve_label='Approve'))
        edit.items.extend([{}, {}, {}, {}])
        edit.capture('agent-edit')
        native(binary, directory, env, library, edit, 'edit')

        agents = json.loads(subprocess.check_output([str(binary), 'agent', 'list', '--json'], env=env, text=True))
        (directory / 'agents.json').write_text(json.dumps(agents, indent=2))
        values = agents if isinstance(agents, list) else agents['agents']
        pane = next(value['pane_id'] for value in values if value.get('provider') == 'codex')
        original = wait_review(binary, env, pane)
        (directory / 'original.json').write_text(json.dumps(original, ensure_ascii=False, indent=2))
        assert original['source'] == 'provider_patch', original
        assert not original['comments'], original
        assert (directory / 'slug.py').read_text().endswith('    return normalized.replace(" ", "-")\n')

        draft = Actions(directory)
        draft.items.extend([{}, dict(click_label='Review changes'), dict(wait_label='Comment', wait_seconds=20), {}, {}])
        for key in ['j'] * 10 + ['k', 'v', 'j', 'c']:
            draft.text(key)
        draft.items.extend([{}, {}])
        draft.text(FEEDBACK)
        draft.items.append(dict(expect_value=dict(label='Review comment', value=FEEDBACK)))
        draft.items.append(dict(wait=str(directory / 'draft-saved'), wait_seconds=25))
        draft.capture('draft')
        native(binary, directory, env, library, draft, 'draft', checks={
            'draft-saved': lambda: any(comment['body'] == FEEDBACK and comment['draft']
                                       and comment['first_line'] == 3 and comment['last_line'] == 4
                                       for comment in show(binary, env, pane, original['edition_id'])['comments'])})
        persisted = show(binary, env, pane, original['edition_id'])
        assert len(persisted['comments']) == 1, persisted
        comment = persisted['comments'][0]
        assert comment['draft'] and comment['body'] == FEEDBACK, comment
        assert comment['first_line'] == 3 and comment['last_line'] == 4, comment
        (directory / 'persisted-draft.json').write_text(json.dumps(persisted, ensure_ascii=False, indent=2))

        submit = Actions(directory)
        submit.items.extend([{}, dict(click_label='Review changes'), dict(wait_label='Comment', wait_seconds=20), {}, {},
                             dict(click_label='Open'), {}, {}, dict(expect_value=dict(label='Review comment', value=FEEDBACK))])
        submit.key('\r', 36, cmd=True)
        submit.items.extend([dict(wait=str(directory / 'comment-saved'), wait_seconds=25), dict(click_label='Send review'),
                             dict(wait=str(directory / 'request-2.json'), wait_seconds=25),
                             dict(wait=str(directory / 'review-delivered'), wait_seconds=25)])
        submit.capture('sent')
        native(binary, directory, env, library, submit, 'submit', checks={
            'comment-saved': lambda: any(comment['body'] == FEEDBACK and not comment['draft']
                                         for comment in show(binary, env, pane, original['edition_id'])['comments']),
            'review-delivered': lambda: show(binary, env, pane, original['edition_id'])['delivery'] == 'delivered'})
        os.kill(int((directory / 'codex.pid').read_text()), 0)

        returned = Actions(directory)
        returned.items.extend([dict(wait=str(directory / 'turn-2.json'), wait_seconds=150, approve_label='Approve'),
                               dict(wait=str(directory / 'correction-recorded'), wait_seconds=25), {},
                               dict(click_label='Review changes'), dict(wait_label='Comment', wait_seconds=20), {}, {}])
        returned.capture('correction')
        returned.items.extend([dict(click_label='Older edit'), {}, {}, {}, dict(click_label='Open'), {}, {}])
        returned.capture('original-comment')
        native(binary, directory, env, library, returned, 'returned', checks={
            'correction-recorded': lambda: show(binary, env, pane)['edition_id'] > original['edition_id']})
        latest = show(binary, env, pane)
        sent = show(binary, env, pane, original['edition_id'])
        assert latest['edition_id'] != original['edition_id'], latest
        assert sent['patch'] == original['patch'] and sent['comments'][0]['body'] == FEEDBACK, sent
        assert sent['delivery'] == 'delivered', sent
        first, second = [json.loads((directory / f'request-{index}.json').read_text()) for index in [1, 2]]
        assert first['threadId'] == second['threadId']
        assert FEEDBACK in second['input'][0]['text'], second
        namespace = {}
        exec((directory / 'slug.py').read_text(), namespace)
        for source, expected in [('  Café  Mundo\t ', 'café-mundo'), ('\t A\n B ', 'a-b'), ('', '')]:
            assert namespace['slugify'](source) == expected
        result = dict(success=True, production_runtime=True, native_gui=True,
                      same_agent_session=True, saved_range=[3, 4], unsent_draft_survived_window_close=True,
                      editions=[original['edition_id'], latest['edition_id']], feedback_delivered=True,
                      provider_survived_window_close=True, correction_verified=True)
        (directory / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2))
    finally:
        shutdown = perf_e2e.stop_runtime(str(binary), env)
        (directory / 'shutdown.json').write_text(json.dumps(shutdown, indent=2) + '\n')
        assert shutdown['exited'] and shutdown['socket_removed'] and shutdown['cleanup_complete'], shutdown


if __name__ == '__main__':
    main()
