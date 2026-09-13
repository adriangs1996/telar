#!/usr/bin/env python3
"""Check native repeated keys in Neovim and capture an unpatched font's icons.

AppKit events carry explicit press/repeat/release phases. This checks the native
text-input and child path, not generation of hardware key-repeat events.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

from gui_multiplexer import Actions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('directory', type=Path, help='new short /tmp directory')
    options = parser.parse_args()
    binary = options.binary.resolve()
    nvim = shutil.which('nvim')
    if nvim is None:
        parser.error('nvim must be installed')
    directory = options.directory.resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    config = directory / 'config.lua'
    config.write_text('''return { api_version = 2, theme = 'vesper',
      gui = { font = { family = 'DejaVu Sans Mono', size = 22, line_height = 1.4,
                      thicken = true, thicken_strength = 255 },
              cursor = { blink = false } } }
''')
    sample = directory / 'icons.txt'
    sample.write_text('DejaVu Sans Mono: ASCII remains in the selected font\n'
                      'Nerd folders: \uf07b \uf115 \uf07c   file: \uf15b   code: \uf121\n'
                      'Nerd status: \uf017 \uf240 \uf2db   dev: \ue7a8 \ue60b\n'
                      'Supplementary icons: \U000f035b \U000f07c0 \U000f17c8\n'
                      + ''.join(f'line {index:02d}\n' for index in range(5, 61)))
    init = directory / 'init.vim'
    init.write_text("set nowrap noswapfile\n"
                    "autocmd VimEnter * call writefile(['ready'], '" + str(directory / 'ready') + "')\n")
    actions = Actions(directory)
    actions.items.append(dict(wait=str(directory / 'ready')))
    actions.capture('icons')
    actions.items.append(dict(key='j', code=38, phase='press'))
    actions.items.extend(dict(key='j', code=38, phase='repeat') for _ in range(10))
    actions.items.append(dict(key='j', code=38, phase='release'))
    actions.text(":call writefile([string(line('.'))], '" + str(directory / 'line') + "')")
    actions.key('\r', 36)
    actions.items.append(dict(wait=str(directory / 'line')))
    actions.capture('repeated')
    script = directory / 'actions.json'
    script.write_text(json.dumps(actions.items))
    library = directory / 'driver.dylib'
    subprocess.run(['clang', '-dynamiclib', '-fobjc-arc', '-framework', 'AppKit',
                    str(Path(__file__).with_name('gui_actions.m')), '-o', str(library)], check=True)
    env = {key: value for key, value in os.environ.items()
           if not key.startswith('TELAR_') and key != 'DYLD_INSERT_LIBRARIES'}
    env.update(TELAR_SOCKET=str(directory / 'runtime.sock'), TELAR_HISTORY=str(directory / 'history.db'))
    server_log = (directory / 'server.log').open('w')
    server = subprocess.Popen([str(binary), 'server', '--no-config'], env=env, cwd=directory,
                              stdout=server_log, stderr=server_log)
    try:
        deadline = time.monotonic() + 5
        while not (directory / 'runtime.sock').exists():
            if server.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError('The isolated runtime did not start; see server.log')
            time.sleep(0.02)
        with (directory / 'gui.log').open('w') as log:
            subprocess.run([str(binary), 'gui', '--config', str(config), nvim,
                            '-u', 'NONE', '-i', 'NONE', '-n', '-S', str(init), str(sample)],
                           env=dict(env, DYLD_INSERT_LIBRARIES=str(library), TELAR_GUI_ACTIONS=str(script)),
                           cwd=directory, stdout=log, stderr=log, timeout=45, check=True)
        line = int((directory / 'line').read_text().strip())
        report = dict(line=line, expected_line=12, repeats=10, font='DejaVu Sans Mono')
        (directory / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
        assert line == 12, report
        print(json.dumps(report))
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
