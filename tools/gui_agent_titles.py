#!/usr/bin/env python3
"""Verify managed session titles with local fixtures and GUI detach/reconnect."""

import argparse
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import time

from gui_agent_lifecycle import FAKE_CODEX, wait_for
from gui_multiplexer import Actions, exercise


TITLE = 'Trace session titles'
TAB_LABEL = 'Agent work'
PROMPT = ('Trace session titles from the agent composer through the runtime.\n'
          'Keep its generated title after reconnecting.')
NORMALIZED_PROMPT = PROMPT.replace('\n', ' ')
GENERATOR = r'''
import json
import os
from pathlib import Path
import sys
import time

directory = Path(sys.argv[1])
request = sys.stdin.read()
with (directory / 'title-requests.jsonl').open('a') as log:
    log.write(json.dumps({'pid': os.getpid(), 'stdin': request, 'argv': sys.argv}) + '\n')
(directory / 'title-started').touch()
deadline = time.monotonic() + 25
while not (directory / 'release-title').exists():
    if time.monotonic() > deadline:
        raise RuntimeError('Title fixture was not released before its deadline')
    time.sleep(.02)
print('Trace session titles', flush=True)
'''


def agents(binary, env):
    return json.loads(subprocess.check_output(
        [str(binary), 'agent', 'list', '--json'], env=env, timeout=10))


def wait_title(binary, env, expected):
    deadline = time.monotonic() + 10
    latest = None
    while time.monotonic() < deadline:
        latest = agents(binary, env)
        if len(latest['agents']) == 1 and latest['agents'][0]['title'] == expected:
            return latest
        time.sleep(.05)
    raise RuntimeError(f'Title did not become {expected!r}: {latest!r}')


def persisted_title(directory, agent):
    connection = sqlite3.connect((directory / 'history.db').as_uri() + '?mode=ro', uri=True, timeout=1)
    connection.row_factory = sqlite3.Row
    latest = []
    try:
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            latest = [dict(row) for row in connection.execute(
                'SELECT pane_id, tab_id, title, title_source, title_state FROM session '
                'WHERE pane_id = ? AND workspace_path = ?', (agent['pane_id'], str(directory)))]
            # AgentTitleSource.generated is 1 and AgentTitleState.ready is 2.
            if (len(latest) == 1 and latest[0]['title'] == TITLE and
                    latest[0]['title_source'] == 1 and latest[0]['title_state'] == 2):
                return latest[0]
            time.sleep(.05)
        raise RuntimeError(f'Generated title was not persisted: {latest!r}')
    finally:
        connection.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('directory', type=Path, help='new short /tmp directory')
    parser.add_argument('--driver-source', type=Path, default=Path(__file__).with_name('gui_actions.m'))
    args = parser.parse_args()
    binary, directory = args.binary.resolve(), args.directory.resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    fake = directory / 'codex'
    fake.write_text(f'#!{sys.executable}\n' + FAKE_CODEX)
    fake.chmod(0o700)
    generator = directory / 'title_generator.py'
    generator.write_text(GENERATOR)
    config = directory / 'config.lua'
    command = ', '.join(json.dumps(value, ensure_ascii=False) for value in
                        [sys.executable, str(generator), str(directory)])
    config.write_text('return { api_version = 2, runtime = { agent_descriptions = { '
                      f'command = {{ {command} }}, timeout_ms = 30000 '
                      '} } }\n')
    driver_source = args.driver_source.read_text()
    marker = '            if (action[@"key"]) send_key(view, action);'
    assert driver_source.count(marker) == 1, 'Native driver keyboard entrypoint changed'
    driver_source = driver_source.replace(marker, '''            if ((action[@"key"] || action[@"text"] || action[@"click_label"]) &&
                (!NSApp.isActive || !window.isKeyWindow)) {
                fprintf(stderr, "Native title test lost application/window focus before action %lu; stopping without reactivating the window\\n", (unsigned long)index);
                abort();
            }
''' + marker)
    driver = directory / 'actions.m'
    driver.write_text(driver_source)
    library = directory / 'driver.dylib'
    subprocess.run(['clang', '-dynamiclib', '-fobjc-arc', '-framework', 'AppKit',
                    '-I', str(Path(__file__).resolve().parent),
                    str(driver), '-o', str(library)], check=True)
    env = {key: value for key, value in os.environ.items() if not key.startswith('TELAR_')}
    env.update(TELAR_SOCKET=str(directory / 'runtime.sock'), TELAR_HISTORY=str(directory / 'history.db'),
               FAKE_CODEX_DIRECTORY=str(directory), PATH=str(directory) + os.pathsep + env.get('PATH', ''))
    subprocess.run([str(binary), 'server', '--background', '--config', str(config)],
                   env=env, cwd=directory, check=True)
    try:
        first = Actions(directory)
        first.items.append(dict(resize=[1100, 800]))
        first.items.extend([{}] * 8)
        first.capture('initial-window')
        first.prefix('a', 0)
        first.capture('agent-created')
        first.items.append(dict(wait=str(directory / 'provider-ready')))
        first.items.extend([{}] * 5)
        first.capture('placeholder')
        first.items.append(dict(click_label='Message to agent'))
        first.text(PROMPT)
        first.items.append(dict(expect_value=dict(label='Message to agent', value=PROMPT)))
        first.key('\r', 36)
        first.items.append(dict(wait=str(directory / 'title-started')))
        first.items.append(dict(wait=str(directory / 'stream-visible')))
        first.items.extend([{}] * 3)
        first.capture('pending-title')
        exercise(binary, directory, env, library, first, 'first')

        provider_pid = int((directory / 'codex.pid').read_text())
        os.kill(provider_pid, 0)
        pending = agents(binary, env)
        assert len(pending['agents']) == 1, pending
        assert pending['agents'][0]['title'] == 'New Codex session', pending
        received = json.loads((directory / 'received-prompt.json').read_text())
        assert received == [dict(type='text', text=PROMPT)], received
        requests = [json.loads(line) for line in (directory / 'title-requests.jsonl').read_text().splitlines()]
        assert len(requests) == 1, requests
        assert requests[0]['stdin'].endswith(NORMALIZED_PROMPT + '\n'), requests
        assert PROMPT not in requests[0]['stdin'], requests
        assert all(PROMPT not in value and NORMALIZED_PROMPT not in value
                   for value in requests[0]['argv']), requests
        os.kill(requests[0]['pid'], 0)
        (directory / 'release-title').touch()
        generated = wait_title(binary, env, TITLE)
        (directory / 'generated-while-detached.json').write_text(json.dumps(generated, indent=2) + '\n')
        (directory / 'finish-detached').touch()
        wait_for(directory / 'background-complete')
        os.kill(provider_pid, 0)

        reconnect = Actions(directory)
        reconnect.items.append(dict(resize=[1100, 800]))
        reconnect.items.extend([{}] * 8)
        reconnect.items.append(dict(click_label='Message to agent'))
        reconnect.items.append(dict(expect_value=dict(label='Message to agent', value='')))
        reconnect.capture('reconnected-title')
        reconnect.rename('T', TAB_LABEL)
        reconnect.capture('renamed-tab')
        exercise(binary, directory, env, library, reconnect, 'reconnect')
        retained = agents(binary, env)
        assert len(retained['agents']) == 1, retained
        assert retained['agents'][0]['title'] == TITLE, retained
        assert retained['agents'][0]['tab'] == TAB_LABEL, retained
        assert retained['agents'][0]['pane_id'] == generated['agents'][0]['pane_id'], retained
        assert retained['agents'][0]['pane_generation'] == generated['agents'][0]['pane_generation'], retained
        persisted = persisted_title(directory, retained['agents'][0])
        assert persisted['tab_id'] == retained['agents'][0]['tab_id'], persisted
        os.kill(provider_pid, 0)
        requests = [json.loads(line) for line in (directory / 'title-requests.jsonl').read_text().splitlines()]
        assert len(requests) == 1, requests
        provider = [json.loads(line) for line in (directory / 'provider.jsonl').read_text().splitlines()]
        for method in ['initialize', 'thread/start', 'turn/start']:
            assert sum(request.get('method') == method for request in provider) == 1, provider
        screenshots = ['placeholder.png', 'pending-title.png', 'reconnected-title.png', 'renamed-tab.png']
        for name in screenshots:
            assert (directory / name).stat().st_size > 0, name
        result = dict(fake_provider=True, fake_title_generator=True, model_calls=0,
                      generator_calls=len(requests), generation_completed_while_gui_detached=True,
                      title=TITLE, title_survived_gui_reconnect=True, tab_rename_kept_session_title=True,
                      same_provider_after_reconnect=True, manual_session_rename_gui_available=False,
                      multiline_prompt_preserved=True, generator_input_normalized=True,
                      title_persisted_in_history=True, history_session=persisted,
                      provider_pid=provider_pid, before=pending, generated=generated, reconnected=retained,
                      sidebar_visual_review_required=True, screenshots=screenshots)
        (directory / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2))
    finally:
        subprocess.run([str(binary), 'server', 'stop'], env=env,
                       stdout=subprocess.DEVNULL, timeout=10, check=False)


if __name__ == '__main__':
    main()
