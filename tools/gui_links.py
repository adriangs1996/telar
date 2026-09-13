#!/usr/bin/env python3
"""Check native macOS link hover, OSC 22, file opening and child survival.

Uses synthetic AppKit pointer events and records both desiredPointerShape and
NSCursor. A uniquely colored terminal cell provides exact rendered geometry.
Only file:// is opened, through an isolated EDITOR stub; HTTP stays a hover test.
Usage: python3 tools/gui_links.py /path/to/telar /tmp/telar-links-probe
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
    target = directory / 'document with space.txt'
    target.write_text('Native file link fixture.\n')
    child = directory / 'child.py'
    child.write_text('''import fcntl, json, os, struct, termios, time, tty
from pathlib import Path
tty.setraw(0)
deadline = time.monotonic() + 8
while True:
    rows, cols, xpixel, ypixel = struct.unpack('HHHH', fcntl.ioctl(0, termios.TIOCGWINSZ, bytes(8)))
    if xpixel and ypixel:
        break
    if time.monotonic() >= deadline:
        raise RuntimeError('GUI metrics did not reach the child PTY')
    time.sleep(.02)
uri = (Path.cwd() / 'document with space.txt').as_uri()
if len(uri) >= cols:
    raise RuntimeError(f'Fixture URI requires {len(uri)} columns; pane has {cols}')
os.write(1, ('\\x1b[2J\\x1b[H\\x1b[?25l\\x1b]22;default\\x07'
             '\\x1b[48;2;23;57;91m \\x1b[0m Native pointer probe\\r\\n'
             'HTTP hover and an isolated file opener\\r\\n'
             'https://example.invalid/probe\\r\\n' + uri + '\\r\\n'
             'c: OSC 22 crosshair   t: OSC 22 text\\r\\n').encode())
Path('child.json').write_text(json.dumps(dict(pid=os.getpid(), rows=rows, cols=cols,
                                            xpixel=xpixel, ypixel=ypixel, uri=uri)))
while True:
    data = os.read(0, 256)
    if not data:
        break
    for key in data:
        shape = {ord('c'): 'crosshair', ord('t'): 'text'}.get(key)
        if shape:
            os.write(1, f'\\x1b]22;{shape}\\x07'.encode())
            Path(shape + '.ready').write_text('ready')
''')
    editor = directory / 'editor'
    editor.write_text(f'''#!{sys.executable}
import json, os, signal, sys
from pathlib import Path
Path({str(directory / 'editor.json')!r}).write_text(json.dumps(dict(pid=os.getpid(), argv=sys.argv)))
while True:
    signal.pause()
''')
    editor.chmod(0o700)
    config = directory / 'config.lua'
    config.write_text('''return { api_version = 2, theme = 'vesper',
      client = { sidebar = { visible = false }, pane_gaps = false },
      gui = { font = { family = 'DejaVu Sans Mono', size = 15, line_height = 1.1 },
              window = { padding = { x = 8, y = 6 } }, cursor = { blink = false } } }
''')
    return child, editor, config, target


def actions_for(directory):
    actions = Actions(directory)

    def pointer(kind, cell=None, **mods):
        actions.items.append(dict(pointer=kind, **({'cell': cell} if cell else {}), **mods))

    def observe(name, shape, native):
        actions.items.append(dict(assert_pointer=shape, native_cursor=native))
        actions.capture(name)
        actions.items.append(dict(record=str(directory / f'{name}.json')))

    actions.items.extend([dict(wait=str(directory / 'child.json')), dict(wait_marker=True)])
    pointer('enter', [4, 2])
    observe('plain', 8, 'text')
    pointer('modifiers', cmd=True)
    observe('hover', 3, 'pointer')
    pointer('modifiers')
    observe('released-modifier', 8, 'text')
    actions.text('c')
    actions.items.append(dict(wait=str(directory / 'crosshair.ready')))
    observe('osc-crosshair', 7, 'crosshair')
    actions.text('t')
    actions.items.append(dict(wait=str(directory / 'text.ready')))
    observe('osc-text', 8, 'text')
    pointer('move', [4, 3], cmd=True)
    observe('file-hover', 3, 'pointer')
    pointer('press', [4, 3], cmd=True)
    pointer('release', [4, 3], cmd=True)
    actions.items.append(dict(wait=str(directory / 'editor.json')))
    actions.capture('editor-tab')
    actions.prefix('p', 35)
    actions.items.append(dict(wait_marker=True))
    pointer('move', [4, 2])
    observe('original-tab', 8, 'text')
    actions.prefix('s', 1)
    actions.items.append(dict(wait_marker=True))
    pointer('move', [-1, 1])
    observe('sidebar-resize', 18, 'col_resize')
    actions.prefix('s', 1)
    actions.items.append(dict(wait_marker=True))
    pointer('enter', [4, 2], cmd=True)
    observe('restored-hover', 3, 'pointer')
    pointer('leave', [4, 2])
    observe('leave', 0, 'default')
    return actions


def has_link_underline(record, row, columns):
    x, y, width, height = record['marker']
    expected = [x, y + (row + 1) * height - 2, columns * width, 1]
    return any(all(abs(a - b) < .01 for a, b in zip(line, expected))
               for line in record['horizontal_rules'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('directory', type=Path, help='new short /tmp directory')
    options = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('this probe requires macOS and AppKit')
    binary = options.binary.resolve(strict=True)
    directory = options.directory.resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    child, editor, config, target = write_fixture(directory)
    actions = actions_for(directory)
    script = directory / 'actions.json'
    script.write_text(json.dumps(actions.items, indent=2) + '\n')
    library = directory / 'driver.dylib'
    subprocess.run(['clang', '-dynamiclib', '-fobjc-arc', '-framework', 'AppKit',
                    str(Path(__file__).with_name('gui_actions.m')), '-o', str(library)], check=True)
    env = {key: value for key, value in os.environ.items()
           if not key.startswith('TELAR_') and key != 'DYLD_INSERT_LIBRARIES'}
    env.update(TELAR_SOCKET=str(directory / 'runtime.sock'), TELAR_HISTORY=str(directory / 'history.db'),
               EDITOR=str(editor))
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
        names = ['plain', 'hover', 'released-modifier', 'osc-crosshair', 'osc-text', 'file-hover',
                 'original-tab', 'sidebar-resize', 'restored-hover', 'leave']
        records = {name: json.loads((directory / f'{name}.json').read_text()) for name in names}
        opened = json.loads((directory / 'editor.json').read_text())
        terminal = json.loads((directory / 'child.json').read_text())
        assert opened['argv'] == [str(editor), str(target)], opened
        columns = len('https://example.invalid/probe')
        assert not has_link_underline(records['plain'], 2, columns), records
        assert has_link_underline(records['hover'], 2, columns), records
        assert not has_link_underline(records['released-modifier'], 2, columns), records
        assert has_link_underline(records['file-hover'], 3, len(terminal['uri'])), records
        assert not has_link_underline(records['leave'], 2, columns), records
        marker = records['plain']['marker']
        assert marker[2] == terminal['xpixel'] / terminal['cols'], (marker, terminal)
        assert marker[3] == terminal['ypixel'] / terminal['rows'], (marker, terminal)
        for pid in (terminal['pid'], opened['pid']):
            os.kill(pid, 0)
        result = dict(records=records, editor=opened, terminal=terminal,
                      file_opened=True, children_survived_window_close=True, external_http_opened=False)
        (directory / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2))
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
