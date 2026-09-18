#!/usr/bin/env python3
"""Check native global bindings while an agent composer owns keyboard focus."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from gui_agent_lifecycle import FAKE_CODEX
from gui_multiplexer import Actions


CONFIG = '''local telar = require("telar")
return telar.config({
  api_version = 2,
  client = {
    keybindings = {
      telar.bind_global({ "ctrl+r" }, "history-palette"),
      telar.bind_global({ "ctrl+l" }, telar.action.navigate_pane({ direction = "right" })),
      telar.bind_global({ "alt+n" }, telar.action.resize_sidebar({ direction = "left" })),
    },
  },
})
'''

CONTROL_PROBE = '''
            if (action[@"record_control"]) {
                NSDictionary *probe = action[@"record_control"];
                id control = find_control([view accessibilityChildren], probe[@"label"]);
                if (control == nil) abort();
                NSRect frame = [control accessibilityFrame];
                NSDictionary *record = @{@"x": @(frame.origin.x), @"y": @(frame.origin.y),
                    @"width": @(frame.size.width), @"height": @(frame.size.height),
                    @"value": [control accessibilityValue] ?: @""};
                NSData *data = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
                if (![data writeToFile:probe[@"path"] atomically:YES]) abort();
            }
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('directory', type=Path, help='new short /tmp directory')
    parser.add_argument('--driver-source', type=Path,
                        default=Path(__file__).with_name('gui_actions.m'))
    args = parser.parse_args()
    binary, directory = args.binary.resolve(), args.directory.resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    config = directory / 'config.lua'
    config.write_text(CONFIG)
    fake = directory / 'codex'
    fake.write_text(f'#!{sys.executable}\n' + FAKE_CODEX)
    fake.chmod(0o700)

    driver_source = args.driver_source.read_text()
    marker = '            if (action[@"expect_value"]) {'
    assert driver_source.count(marker) == 1, 'Native driver assertion entrypoint changed'
    driver = directory / 'actions.m'
    driver.write_text(driver_source.replace(marker, CONTROL_PROBE + marker))
    library = directory / 'driver.dylib'
    subprocess.run(['clang', '-dynamiclib', '-fobjc-arc', '-I' + str(Path(__file__).resolve().parent),
                    '-framework', 'AppKit', str(driver), '-o', str(library)], check=True)

    env = {key: value for key, value in os.environ.items() if not key.startswith('TELAR_')}
    env.update(TELAR_SOCKET=str(directory / 'runtime.sock'), TELAR_HISTORY=str(directory / 'history.db'),
               FAKE_CODEX_DIRECTORY=str(directory), PATH=str(directory) + os.pathsep + env.get('PATH', ''))
    subprocess.run([str(binary), 'config', 'check', str(config)], env=env, cwd=directory, check=True)
    subprocess.run([str(binary), 'server', '--background', '--no-config'], env=env, cwd=directory, check=True)
    try:
        draft = 'Keep this draft through global shortcuts.'
        actions = Actions(directory)
        actions.items.append(dict(resize=[1100, 900]))
        actions.items.extend([{}] * 12)
        actions.prefix('a', 0)
        actions.items.append(dict(wait=str(directory / 'provider-ready')))
        actions.items.extend([{}] * 6)
        actions.items.append(dict(click_label='Message to agent'))
        actions.text(draft)
        actions.items.append(dict(expect_value=dict(label='Message to agent', value=draft)))
        actions.capture('draft-before')
        actions.key('r', 15, ctrl=True)
        actions.items.extend([{}] * 6)
        actions.items.append(dict(expect_value=dict(label='Search command history', value='')))
        actions.text('query belongs to history')
        actions.items.append(dict(expect_value=dict(label='Search command history', value='query belongs to history')))
        actions.capture('history-open')
        actions.key('\x1b', 53)
        actions.items.extend([{}] * 6)
        actions.items.append(dict(expect_value=dict(label='Message to agent', value=draft)))
        actions.text(' Still editing.')
        draft += ' Still editing.'
        actions.items.append(dict(expect_value=dict(label='Message to agent', value=draft)))
        actions.items.append(dict(record_control=dict(label='Message to agent', path=str(directory / 'before-resize.json'))))
        actions.key('n', 45, alt=True)
        actions.items.extend([{}] * 6)
        actions.items.append(dict(record_control=dict(label='Message to agent', path=str(directory / 'after-resize.json'))))
        actions.items.append(dict(expect_value=dict(label='Message to agent', value=draft)))
        actions.capture('draft-after')
        script = directory / 'bindings.json'
        script.write_text(json.dumps(actions.items))
        with (directory / 'bindings.log').open('w') as log:
            subprocess.run([str(binary), 'gui', '--config', str(config), '/bin/sh'], cwd=directory,
                           env=dict(env, DYLD_INSERT_LIBRARIES=str(library), TELAR_GUI_ACTIONS=str(script)),
                           stdout=log, stderr=log, timeout=100, check=True)
        before = json.loads((directory / 'before-resize.json').read_text())
        after = json.loads((directory / 'after-resize.json').read_text())
        assert before['x'] != after['x'] or before['width'] != after['width'], (before, after)
        assert before['value'] == after['value'] == draft, (before, after)
        requests = [json.loads(line) for line in (directory / 'provider.jsonl').read_text().splitlines()]
        assert sum(message.get('method') == 'initialize' for message in requests) == 1
        assert not any(message.get('method') == 'turn/start' for message in requests), requests
        result = dict(fake_provider=True, global_history_from_composer=True, history_query_isolated=True,
                      escape_restores_composer_focus=True, draft_preserved=True, global_sidebar_resize=True,
                      model_calls=0, before_resize=before, after_resize=after,
                      screenshots=sorted(path.name for path in directory.glob('*.png')))
        (directory / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2))
    finally:
        subprocess.run([str(binary), 'server', 'stop'], env=env, stdout=subprocess.DEVNULL,
                       timeout=10, check=False)


if __name__ == '__main__':
    main()
