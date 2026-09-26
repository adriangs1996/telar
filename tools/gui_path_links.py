#!/usr/bin/env python3
"""Check that Cmd+click on file paths printed as plain text opens the editor at their line.

Runs an isolated runtime and the native GUI with synthetic AppKit pointer events.
The pane prints a relative path with `:line`, a home path with `:line:column`, a
path that does not exist and an OSC 8 `file://` link with a `#L` fragment. The
configured editor is a stub named `nvim` that records its argv and exits, so each
open must arrive as `nvim +LINE /absolute/path`. Without Cmd a path is plain text.
The window must remain focused; external focus changes abort the probe.
Usage: python3 tools/gui_path_links.py /path/to/telar /short/new/directory
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time

from gui_multiplexer import Actions


def write_fixture(directory):
    (directory / 'src').mkdir()
    (directory / 'src' / 'probe.zig').write_text('one\ntwo\nthree\nfour\n')
    (directory / 'notes').mkdir()
    (directory / 'notes' / 'home.md').write_text('# Home\nsecond line\n')
    fragment_uri = (directory / 'src' / 'probe.zig').as_uri() + '#L4'
    child = directory / 'child.py'
    child.write_text(f'''import json, os, time, tty
from pathlib import Path
tty.setraw(0)
os.write(1, ('\\x1b[2J\\x1b[H\\x1b[?25l'
             '\\x1b[48;2;23;57;91m \\x1b[0m Path probe\\r\\n'
             'see src/probe.zig:3 now\\r\\n'
             'home ~/notes/home.md:2:5 x\\r\\n'
             'gone missing/absent.zig:9\\r\\n'
             '\\x1b]8;;{fragment_uri}\\x1b\\\\fragment link\\x1b]8;;\\x1b\\\\').encode())
Path('child.json').write_text(json.dumps(dict(pid=os.getpid())))
while os.read(0, 256):
    pass
''')
    stub = directory / 'bin' / 'nvim'
    stub.parent.mkdir()
    stub.write_text(f'''#!{sys.executable}
import json, os, sys
from pathlib import Path
directory = Path({str(directory)!r})
opened = len(list(directory.glob('opened-*.json'))) + 1
(directory / f'opened-{{opened}}.json').write_text(json.dumps(dict(argv=sys.argv, cwd=os.getcwd())))
''')
    stub.chmod(0o700)
    config = directory / 'config.lua'
    config.write_text(f'''return {{ api_version = 2, theme = 'vesper',
      client = {{ editor = {str(stub)!r}, sidebar = {{ visible = false }}, pane_gaps = false }},
      gui = {{ font = {{ family = 'DejaVu Sans Mono', size = 15, line_height = 1.1 }},
              window = {{ padding = {{ x = 8, y = 6 }} }}, cursor = {{ blink = false }} }} }}
''')
    return child, stub, config


def actions_for(directory):
    actions = Actions(directory)

    def pointer(kind, cell=None, **mods):
        action = dict(pointer=kind, **({'cell': cell} if cell else {}), **mods)
        if kind == 'press':
            action.update(assert_pointer=3, native_cursor='pointer')
        actions.items.append(action)

    def observe(name, shape, native):
        actions.items.append(dict(assert_pointer=shape, native_cursor=native))
        actions.items.append(dict(assert_pointer=shape, native_cursor=native,
                                  record=str(directory / f'{name}.json')))

    def click(cell, opened):
        pointer('move', cell, cmd=True)
        pointer('press', cell, cmd=True)
        pointer('release', cell, cmd=True)
        if opened:
            actions.items.append(dict(wait=str(directory / opened)))
        actions.items.extend([{}] * 30)
        actions.items.append(dict(wait_marker=True))

    actions.items.extend([dict(wait=str(directory / 'child.json')), dict(wait_marker=True)])
    pointer('enter', [6, 1])
    observe('plain-path', 8, 'text')
    pointer('modifiers', cmd=True)
    observe('cmd-path', 3, 'pointer')
    pointer('modifiers')
    click([6, 1], 'opened-1.json')
    click([8, 2], 'opened-2.json')
    click([8, 3], None)
    click([3, 4], 'opened-3.json')
    pointer('leave', [6, 1])
    return actions


def has_link_underline(record, span):
    column, row, columns = span
    x, y, width, height = record['marker']
    expected = [x + column * width, y + (row + 1) * height - 2, columns * width, 1]
    return any(all(abs(a - b) < .01 for a, b in zip(line, expected))
               for line in record['horizontal_rules'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('directory', type=Path, help='new short directory; the runtime socket lives in it')
    options = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('this probe requires macOS and AppKit')
    binary = options.binary.resolve(strict=True)
    directory = options.directory.resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    child, stub, config = write_fixture(directory)
    actions = actions_for(directory)
    script = directory / 'actions.json'
    script.write_text(json.dumps(actions.items, indent=2) + '\n')
    library = directory / 'driver.dylib'
    subprocess.run(['clang', '-dynamiclib', '-fobjc-arc', '-framework', 'AppKit',
                    str(Path(__file__).with_name('gui_actions.m')), '-o', str(library)], check=True)
    env = {key: value for key, value in os.environ.items()
           if not key.startswith('TELAR_') and key not in ('DYLD_INSERT_LIBRARIES', 'EDITOR', 'VISUAL')}
    env.update(TELAR_SOCKET=str(directory / 'runtime.sock'), TELAR_HISTORY=str(directory / 'history.db'),
               HOME=str(directory))
    server_log = (directory / 'server.log').open('w')
    server = subprocess.Popen([str(binary), 'server', '--no-config'], env=env, cwd=directory,
                              stdout=server_log, stderr=server_log)
    try:
        deadline = time.monotonic() + 8
        while not (directory / 'runtime.sock').exists():
            if server.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError('The isolated runtime did not start; see server.log')
            time.sleep(0.02)
        with (directory / 'gui.log').open('w') as log:
            subprocess.run([str(binary), 'gui', '--config', str(config), sys.executable, str(child)],
                           env=dict(env, DYLD_INSERT_LIBRARIES=str(library), TELAR_GUI_ACTIONS=str(script),
                                    TELAR_GUI_MARKER='23,57,91'), cwd=directory, stdout=log, stderr=log,
                           timeout=90, check=True)
        records = {name: json.loads((directory / f'{name}.json').read_text()) for name in ('plain-path', 'cmd-path')}
        assert all(record['app_active'] and record['window_key'] for record in records.values()), records
        span = (4, 1, len('src/probe.zig:3'))
        assert not has_link_underline(records['plain-path'], span), records
        assert has_link_underline(records['cmd-path'], span), records
        opened = sorted(directory.glob('opened-*.json'))
        argv = [json.loads(path.read_text())['argv'] for path in opened]
        expected = [
            [str(stub), '+3', str(directory / 'src' / 'probe.zig')],
            [str(stub), '+call cursor(2, 5)', str(directory / 'notes' / 'home.md')],
            [str(stub), '+4', str(directory / 'src' / 'probe.zig')],
        ]
        assert argv == expected, argv
        result = dict(records=records, argv=argv, plain_text_without_cmd=True,
                      relative_path_line=True, home_path_line_column=True,
                      missing_path_opened_nothing=True, file_uri_fragment_line=True)
        (directory / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(dict(argv=argv), indent=2))
    finally:
        subprocess.run([str(binary), 'server', 'stop'], env=env,
                       stdout=subprocess.DEVNULL, timeout=10, check=False)
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait()
        server_log.close()


if __name__ == '__main__':
    main()
