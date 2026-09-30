#!/usr/bin/env python3
"""Exercise pick lists in the native window against a real isolated macOS runtime.

Runs the Pi example from `docs/configuration.md` verbatim, its helper and its
configuration, with HOME, XDG directories and the runtime socket inside the
given directory, and a `pi` on PATH that prints a recorded `pi --list-models`
output. Clicks the thinking level and the model in the bar, types a query,
chooses with Enter, and checks that Pi's settings file changed, kept its other
keys, and that the bar showed the new values without waiting for its interval.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import subprocess

DOCS = Path(__file__).resolve().parent.parent / 'docs' / 'configuration.md'
ENTER = 36


def example_blocks():
    """The helper and the configuration of the documented Pi example."""
    text = DOCS.read_text()
    section = text[text.index("#### Example: Pi's"):]
    python = re.search(r'```python\n(.*?)```', section, re.S).group(1)
    lua = re.search(r'```lua\n(.*?)```', section, re.S).group(1)
    return python, lua


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('directory', type=Path, help='new short /tmp directory')
    parser.add_argument('models', type=Path, help='a recorded `pi --list-models` output')
    args = parser.parse_args()
    binary = args.binary.resolve()
    directory = args.directory.resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    library = directory / 'driver.dylib'
    subprocess.run(['clang', '-dynamiclib', '-fobjc-arc', '-framework', 'AppKit',
                    str(Path(__file__).with_name('gui_actions.m')), '-o', str(library)], check=True)

    home = directory / 'home'
    helper_source, config_source = example_blocks()
    helper = home / '.config' / 'telar' / 'bin' / 'pi-defaults'
    helper.parent.mkdir(parents=True)
    helper.write_text(helper_source)
    helper.chmod(0o700)
    config = directory / 'config.lua'
    config.write_text(config_source)
    tools = directory / 'bin'
    tools.mkdir()
    fake_pi = tools / 'pi'
    fake_pi.write_text(f'#!/bin/sh\nexec cat {shlex.quote(str(args.models.resolve()))}\n')
    fake_pi.chmod(0o700)
    settings = home / '.pi' / 'agent' / 'settings.json'
    settings.parent.mkdir(parents=True)
    settings.write_text(json.dumps({'theme': 'dark', 'defaultThinkingLevel': 'medium'}))

    env = {key: value for key, value in os.environ.items() if not key.startswith(('TELAR_', 'XDG_'))}
    env.update(HOME=str(home), PATH=f'{tools}:{env["PATH"]}',
               XDG_CONFIG_HOME=str(directory / 'config'), XDG_STATE_HOME=str(directory / 'state'),
               XDG_CACHE_HOME=str(directory / 'cache'), XDG_DATA_HOME=str(directory / 'data'),
               XDG_RUNTIME_DIR=str(directory / 'run'),
               TELAR_SOCKET=str(directory / 'runtime.sock'), TELAR_SOCKET_PATH=str(directory / 'runtime.sock'),
               TELAR_HISTORY=str(directory / 'history.db'))
    subprocess.run([str(binary), 'server', '--background', '--no-config'], env=env, cwd=directory, check=True)
    try:
        items = [dict(activate=True), dict(resize=[1400, 820])]

        def settle(steps=6):
            items.extend([{}] * steps)

        def click(label):
            items.append(dict(wait_label=label, wait_seconds=10))
            items.append(dict(activate=True, pointer='press', control=label))
            # The palette opens on the press and covers the bar, so the
            # release lands where the press did.
            items.append(dict(activate=True, pointer='release', reuse_pointer=True))

        def choose(query, name):
            items.append(dict(wait_label='Name or query', wait_seconds=10))
            settle(12)
            items.append(dict(text=query))
            settle()
            items.append(dict(capture=str(directory / f'{name}.png')))
            items.append(dict(key='\r', code=ENTER))

        click('medium')
        choose('hi', 'thinking')
        items.append(dict(wait_label='high', wait_seconds=10))
        click('model')
        choose('opus-5-5', 'model')
        items.append(dict(wait_label='claude-opus-5-5', wait_seconds=10))
        settle()
        items.append(dict(capture=str(directory / 'bar.png')))
        script = directory / 'pick.json'
        script.write_text(json.dumps(items))
        with (directory / 'pick.log').open('w') as log:
            subprocess.run([str(binary), 'gui', '--config', str(config), '/bin/sh'], cwd=directory,
                           env=dict(env, DYLD_INSERT_LIBRARIES=str(library), TELAR_GUI_ACTIONS=str(script)),
                           stdout=log, stderr=log, timeout=180, check=True)

        written = json.loads(settings.read_text())
        expected = {'theme': 'dark', 'defaultThinkingLevel': 'high',
                    'defaultProvider': 'anthropic', 'defaultModel': 'claude-opus-5-5'}
        assert written == expected, written
        assert not list(settings.parent.glob('.settings.*')), 'a temporary settings file was left behind'
        captured = [name for name in ['thinking', 'model', 'bar'] if (directory / f'{name}.png').exists()]
        print(f'pick checks passed: {written}; window captures: {captured or "none (grant Screen Recording to capture)"}')
    finally:
        subprocess.run([str(binary), 'server', 'stop'], env=env, cwd=directory, check=False)


if __name__ == '__main__':
    main()
