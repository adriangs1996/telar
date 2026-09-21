#!/usr/bin/env python3
"""Exercise diff navigation with the standalone fixture and native AppKit input.

Build first with `zig build build-widget`. This starts no runtime or agent.
Only the window created by this script is closed when the action sequence ends.
"""

import argparse
import json
import os
from pathlib import Path
import signal
import subprocess

from gui_multiplexer import Actions


def record(actions, name):
    actions.items.extend([{}, {}, {}])
    actions.items.append(dict(record=str(actions.directory / f'{name}.json')))
    actions.capture(name)


def sequence(directory):
    actions = Actions(directory)
    actions.items.append(dict(activate=True, resize=[1100, 520]))
    actions.items.append(dict(wait_label='Diff review'))
    record(actions, 'initial')
    actions.text('G')
    record(actions, 'last-line')
    actions.text('g')
    actions.text('g')
    record(actions, 'first-line')
    actions.key('d', 2, ctrl=True)
    record(actions, 'half-page-down')
    actions.key('u', 32, ctrl=True)
    record(actions, 'half-page-up')

    actions.text('/')
    actions.items.append(dict(wait_label='Search in diff'))
    actions.text('café')
    actions.items.append(dict(expect_value=dict(label='Search in diff', value='café')))
    record(actions, 'search-unicode')
    actions.key('a', 0, cmd=True)
    actions.text('title')
    actions.items.append(dict(expect_value=dict(label='Search in diff', value='title')))
    record(actions, 'search-active')
    actions.key('\r', 36)
    record(actions, 'search-confirmed')
    actions.text('n')
    record(actions, 'next-match')
    actions.text('N')
    record(actions, 'previous-match')

    actions.key('\x1b', 53)
    actions.text('g')
    actions.text('g')
    actions.text('j')
    actions.text('v')
    actions.text('j')
    actions.text('j')
    record(actions, 'visual-selection')
    actions.text('/')
    actions.items.append(dict(wait_label='Search in diff'))
    actions.text('title')
    actions.items.append(dict(expect_value=dict(label='Search in diff', value='title')))
    record(actions, 'visual-search')
    actions.key('\x1b', 53)
    actions.text('c')
    actions.items.append(dict(wait_label='Review comment'))
    comment = 'Revisar estas tres líneas: selección preservada después de buscar café.'
    actions.text(comment)
    actions.items.append(dict(expect_value=dict(label='Review comment', value=comment)))
    record(actions, 'range-comment')
    return actions


def controls(directory, name, label):
    snapshot = json.loads((directory / f'{name}.json').read_text())
    return [control for control in snapshot['controls'] if control['label'] == label]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path, help='freshly built zig-out/bin/run-widget')
    parser.add_argument('directory', type=Path, help='new directory for screenshots and evidence')
    args = parser.parse_args()
    binary, directory = args.binary.resolve(), args.directory.resolve()
    if binary.name != 'run-widget' or not binary.is_file():
        parser.error('Pass the standalone run-widget binary produced by zig build build-widget')
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    library = directory / 'driver.dylib'
    subprocess.run(['clang', '-dynamiclib', '-fobjc-arc', '-framework', 'AppKit',
                    str(Path(__file__).with_name('gui_actions.m')), '-o', str(library)], check=True)
    actions = sequence(directory)
    script = directory / 'navigation.actions.json'
    script.write_text(json.dumps(actions.items, ensure_ascii=False, indent=2) + '\n')
    env = {key: value for key, value in os.environ.items()
           if not key.startswith('TELAR_') and key != 'DYLD_INSERT_LIBRARIES'}
    env.update(DYLD_INSERT_LIBRARIES=str(library), TELAR_GUI_ACTIONS=str(script))
    with (directory / 'native.log').open('w') as log:
        process = subprocess.Popen([str(binary), 'gui'], cwd=directory, env=env,
                                   stdout=log, stderr=log, start_new_session=True)
        try:
            status = process.wait(timeout=90)
            if status != 0:
                raise subprocess.CalledProcessError(status, process.args)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)
    for name in ('search-unicode', 'search-active', 'visual-search'):
        assert len(controls(directory, name, 'Search in diff')) == 1, name
    assert not controls(directory, 'search-confirmed', 'Search in diff')
    assert len(controls(directory, 'range-comment', 'Review comment')) == 1
    screenshots = sorted(path.name for path in directory.glob('*.png'))
    expected = [Path(action['capture']).name for action in actions.items if 'capture' in action]
    assert screenshots == sorted(expected), (screenshots, expected)
    assert all((directory / name).stat().st_size > 0 for name in screenshots)
    result = dict(success=True, standalone_fixture=True, runtime_started=False, model_calls=0,
                  native_search_field_verified=True, utf8_search_input_verified=True,
                  search_confirmed=True, range_comment_editor_verified=True,
                  motions_exercised=['gg', 'G', 'Ctrl+d', 'Ctrl+u', 'n', 'N', 'v'],
                  visual_review_required=True, owned_gui_exited=process.poll() is not None,
                  gui_pid=process.pid, screenshots=screenshots)
    (directory / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
