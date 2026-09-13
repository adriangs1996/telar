#!/usr/bin/env python3
"""Exercise native multiplexer navigation against a real isolated macOS runtime."""
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess


class Actions:
    def __init__(self, directory):
        self.directory = directory
        self.items = []

    def key(self, text, code=0, **modifiers):
        self.items.append(dict(key=text, code=code, **modifiers))

    def text(self, text):
        self.items.append(dict(text=text))

    def prefix(self, suffix, code=0, **modifiers):
        self.key('b', 11, ctrl=True)
        self.key(suffix, code, **modifiers)
        self.items.extend([{}, {}])

    def record(self, name):
        destination = shlex.quote(str(self.directory / name))
        self.text(f'printf "%s " "$$" > {destination}; stty size >> {destination}')
        self.key('\r', 36)
        self.items.append(dict(wait=str(self.directory / name)))

    def rename(self, action, name):
        self.prefix(action, shift=True)
        self.key('\uf729', 115, shift=True)
        self.text(name)
        self.key('\r', 36)
        self.items.extend([{}, {}, {}])

    def capture(self, name):
        self.items.append(dict(capture=str(self.directory / f'{name}.png')))


def exercise(binary, directory, env, library, actions, name):
    script = directory / f'{name}.json'
    script.write_text(json.dumps(actions.items))
    with (directory / f'{name}.log').open('w') as log:
        subprocess.run([str(binary), 'gui', '--no-config', '/bin/sh'], cwd=directory,
                       env=dict(env, DYLD_INSERT_LIBRARIES=str(library), TELAR_GUI_ACTIONS=str(script)),
                       stdout=log, stderr=log, timeout=100, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('directory', type=Path, help='new short /tmp directory')
    args = parser.parse_args()
    binary = args.binary.resolve()
    directory = args.directory.resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    library = directory / 'driver.dylib'
    subprocess.run(['clang', '-dynamiclib', '-fobjc-arc', '-framework', 'AppKit',
                    str(Path(__file__).with_name('gui_actions.m')), '-o', str(library)], check=True)
    env = {key: value for key, value in os.environ.items() if not key.startswith('TELAR_')}
    env.update(TELAR_SOCKET=str(directory / 'runtime.sock'), TELAR_HISTORY=str(directory / 'history.db'))
    subprocess.run([str(binary), 'server', '--background', '--no-config'], env=env, cwd=directory, check=True)
    try:
        actions = Actions(directory)
        actions.rename('W', 'original')
        actions.record('initial')
        actions.prefix('%', 22, shift=True)
        actions.record('right')
        actions.prefix('"', 39, shift=True)
        actions.record('bottom')
        actions.capture('splits')
        actions.prefix('z', 6)
        actions.record('fullscreen')
        actions.capture('fullscreen')
        actions.prefix('z', 6)
        actions.record('restored')
        actions.items.append(dict(click=[0.75, 0.25]))
        actions.record('pointer-right')
        actions.items.append(dict(click=[0.75, 0.75]))
        actions.record('pointer-bottom')
        actions.prefix('\uf702', 123)
        actions.record('left')
        actions.prefix('s', 1)
        actions.record('sidebar-off')
        actions.prefix('s', 1)
        actions.record('sidebar-on')
        actions.prefix('c', 8)
        actions.rename('T', 'logs')
        actions.record('tab-two')
        actions.prefix('p', 35)
        actions.record('tab-one')
        actions.prefix('n', 45)
        actions.record('tab-again')
        actions.prefix('N', 45, shift=True)
        actions.text('second')
        actions.key('\r', 36)
        actions.items.extend([{}, {}, {}])
        actions.record('workspace-two')
        actions.rename('W', 'renamed')
        actions.capture('workspace')
        actions.prefix('g', 5)
        actions.text('original')
        actions.capture('picker')
        actions.key('\r', 36)
        actions.items.extend([{}, {}, {}])
        actions.record('workspace-back')
        actions.capture('before-close')
        exercise(binary, directory, env, library, actions, 'navigation')
        read = lambda name: tuple(map(int, (directory / name).read_text().split()))
        names = ['initial', 'right', 'bottom', 'fullscreen', 'restored', 'pointer-right', 'pointer-bottom', 'left',
                 'sidebar-off', 'sidebar-on', 'tab-two', 'tab-one', 'tab-again',
                 'workspace-two', 'workspace-back']
        records = {name: read(name) for name in names}
        pid = lambda name: records[name][0]
        assert len({pid(name) for name in ['initial', 'right', 'bottom', 'tab-two', 'workspace-two']}) == 5, records
        assert pid('bottom') == pid('fullscreen') == pid('restored'), records
        assert pid('right') == pid('pointer-right'), records
        assert pid('bottom') == pid('pointer-bottom'), records
        assert pid('initial') == pid('left') == pid('tab-one'), records
        assert pid('tab-two') == pid('tab-again') == pid('workspace-back'), records
        assert records['fullscreen'][1] > records['bottom'][1], records
        assert records['fullscreen'][2] > records['bottom'][2], records
        assert records['restored'] == records['bottom'], records
        assert records['sidebar-off'][2] > records['sidebar-on'][2], records
        for child in {record[0] for record in records.values()}:
            os.kill(child, 0)
        reconnect = Actions(directory)
        reconnect.record('reconnected')
        reconnect.prefix('p', 35)
        reconnect.record('reconnected-split')
        reconnect.capture('reconnected')
        exercise(binary, directory, env, library, reconnect, 'reconnect')
        assert read('reconnected') == records['workspace-back'], records
        assert read('reconnected-split') == records['tab-one'], records
        result = dict(records=records, reconnect=read('reconnected'),
                      shell_survival=True, layout_survival=True)
        (directory / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2))
    finally:
        subprocess.run([str(binary), 'server', 'stop'], env=env, stdout=subprocess.DEVNULL,
                       timeout=10, check=False)


if __name__ == '__main__':
    main()
