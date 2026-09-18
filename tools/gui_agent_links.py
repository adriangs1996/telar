#!/usr/bin/env python3
"""Capture native Markdown link labels and hover previews using a fake Codex."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from gui_agent_messages import FAKE_CODEX
from gui_multiplexer import Actions, exercise


LONG_LABEL = ('Read the complete explanation of input dispatch ordering across native callbacks, '
              'pending queues, widget updates, drawing, presentation completion, and retained '
              'interactive geometry after window resize')
RESPONSE = f'''## Links in an agent response

Inspect [`input`](/Users/adriangonzalez/sandbox/telar/run_widget.zig:346) in the source.

Read the [documentation](https://example.com/docs?foo=1&bar=2) for the protocol.

[{LONG_LABEL}](https://example.com/long-reference?source=agent&view=details)

Link labels remain readable, and copying preserves the original Markdown.
'''

SIMPLE_TURN = '''def turn():
    event('turn/started', {'threadId': 'thread-native', 'turn': {'id': 'turn-native', 'status': 'inProgress'}})
    item('completed', {'id': 'answer', 'type': 'agentMessage', 'phase': 'final_answer', 'text': (root / 'response.txt').read_text()})
    event('turn/completed', {'threadId': 'thread-native', 'turn': {'id': 'turn-native', 'status': 'completed'}})
    (root / 'complete-ready').touch()

'''

CONTROL_HELPERS = '''
static id find_control_prefix(NSArray *children, NSString *prefix) {
    for (id child in children) {
        if ([[child accessibilityLabel] hasPrefix:prefix]) return child;
        id found = find_control_prefix([child accessibilityChildren], prefix);
        if (found != nil) return found;
    }
    return nil;
}

static void collect_link_controls(NSArray *children, NSMutableArray *records) {
    for (id child in children) {
        NSRect frame = [child accessibilityFrame];
        [records addObject:@{@"label": [child accessibilityLabel] ?: @"",
            @"role": [child accessibilityRole] ?: @"", @"x": @(frame.origin.x),
            @"y": @(frame.origin.y), @"width": @(frame.size.width), @"height": @(frame.size.height)}];
        collect_link_controls([child accessibilityChildren], records);
    }
}
'''

CONTROL_ACTIONS = '''
            if (action[@"hover_prefix"]) {
                id control = find_control_prefix([view accessibilityChildren], action[@"hover_prefix"]);
                if (control == nil) abort();
                send_pointer(view, @{@"pointer": @"move", @"control": [control accessibilityLabel]});
            }
            if (action[@"record_controls"]) {
                NSMutableArray *records = [NSMutableArray array];
                collect_link_controls([view accessibilityChildren], records);
                NSData *data = [NSJSONSerialization dataWithJSONObject:records options:NSJSONWritingPrettyPrinted error:nil];
                if (![data writeToFile:action[@"record_controls"] atomically:YES]) abort();
            }
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('directory', type=Path, help='new short /tmp directory')
    parser.add_argument('--driver-source', type=Path, default=Path(__file__).with_name('gui_actions.m'))
    args = parser.parse_args()
    binary, directory = args.binary.resolve(), args.directory.resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    (directory / 'response.txt').write_text(RESPONSE)
    fixture = FAKE_CODEX[:FAKE_CODEX.index('def turn():')] + SIMPLE_TURN + FAKE_CODEX[FAKE_CODEX.index('for line in sys.stdin:'):]
    fake = directory / 'codex'
    fake.write_text(f'#!{sys.executable}\n' + fixture)
    fake.chmod(0o700)

    driver_source = args.driver_source.read_text()
    marker = '            if (action[@"expect_value"]) {'
    assert driver_source.count(marker) == 1, 'Native driver assertion entrypoint changed'
    driver_source = driver_source.replace('static id find_control(', CONTROL_HELPERS + '\nstatic id find_control(', 1)
    driver_source = driver_source.replace(marker, CONTROL_ACTIONS + marker)
    driver = directory / 'actions.m'
    driver.write_text(driver_source)
    library = directory / 'driver.dylib'
    subprocess.run(['clang', '-dynamiclib', '-fobjc-arc', '-I' + str(Path(__file__).resolve().parent),
                    '-framework', 'AppKit', str(driver), '-o', str(library)], check=True)
    env = {key: value for key, value in os.environ.items() if not key.startswith('TELAR_')}
    env.update(TELAR_SOCKET=str(directory / 'runtime.sock'), TELAR_HISTORY=str(directory / 'history.db'),
               FAKE_CODEX_DIRECTORY=str(directory), PATH=str(directory) + os.pathsep + env.get('PATH', ''))
    subprocess.run([str(binary), 'server', '--background', '--no-config'], env=env, cwd=directory, check=True)
    try:
        actions = Actions(directory)
        actions.items.append(dict(resize=[1100, 900]))
        actions.items.extend([{}] * 12)
        actions.prefix('a', 0)
        actions.items.append(dict(wait=str(directory / 'provider-ready')))
        actions.items.extend([{}] * 6)
        actions.items.append(dict(click_label='Message to agent'))
        actions.text('Show link previews.')
        actions.key('\r', 36)
        actions.items.append(dict(wait=str(directory / 'complete-ready')))
        actions.items.extend([{}] * 8)
        actions.items.append(dict(record_controls=str(directory / 'controls.json')))
        actions.capture('labels')
        for label, name in [('input', 'file-tooltip'), ('documentation', 'url-tooltip')]:
            actions.items.append(dict(pointer='move', control=label))
            actions.items.extend([{}] * 6)
            actions.capture(name)
        actions.items.append(dict(hover_prefix='Read'))
        actions.items.extend([{}] * 6)
        actions.capture('wrapped-tooltip')
        actions.items.append(dict(pointer='move', control='Message to agent'))
        actions.items.extend([{}] * 6)
        actions.capture('tooltip-cleared')
        actions.items.append(dict(click_label='Copy response'))
        actions.items.extend([{}] * 3)
        actions.items.append(dict(expect_clipboard=RESPONSE))
        exercise(binary, directory, env, library, actions, 'links')

        controls = json.loads((directory / 'controls.json').read_text())
        labels = [control['label'] for control in controls]
        assert 'input' in labels and 'documentation' in labels, labels
        assert '`input`' not in labels, labels
        wrapped = [control for control in controls if control['label'] and control['label'] in LONG_LABEL
                   and control['label'] not in ('input', 'documentation')]
        assert len({round(control['y'], 2) for control in wrapped}) >= 2, wrapped
        requests = [json.loads(line) for line in (directory / 'provider.jsonl').read_text().splitlines()]
        assert sum(message.get('method') == 'turn/start' for message in requests) == 1
        result = dict(fake_provider=True, model_calls=0, plain_labels=True, code_label_without_backticks=True,
                      wrapped_fragment_rows=len({round(control['y'], 2) for control in wrapped}),
                      copy_preserves_original_markdown=True, tooltip_visual_review_required=True,
                      screenshots=sorted(path.name for path in directory.glob('*.png')))
        (directory / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2))
    finally:
        subprocess.run([str(binary), 'server', 'stop'], env=env, stdout=subprocess.DEVNULL,
                       timeout=10, check=False)


if __name__ == '__main__':
    main()
