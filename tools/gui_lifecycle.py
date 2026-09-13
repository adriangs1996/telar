#!/usr/bin/env python3
"""Verify native input, PTY resize, and shell survival after GUI detach on macOS."""
import argparse
import json
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('directory', type=Path, help='new short /tmp directory')
    parser.add_argument('--config', type=Path, help='native appearance configuration to exercise')
    parser.add_argument('--capture', action='store_true', help='capture the configured terminal window')
    parser.add_argument('--reload', action='store_true', help='exercise hot reload with an isolated generated config')
    args = parser.parse_args()
    if args.reload and args.config:
        parser.error('--reload supplies its own configuration; omit --config')
    binary = args.binary.resolve()
    directory = args.directory.resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    library = directory / 'driver.dylib'
    driver = Path(__file__).with_name('gui_reload.m') if args.reload else Path(__file__).with_suffix('.m')
    subprocess.run(['clang', '-dynamiclib', '-fobjc-arc', '-framework', 'AppKit',
                    str(driver), '-o', str(library)], check=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith('TELAR_')}
    env.update(TELAR_SOCKET=str(directory / 'runtime.sock'),
               TELAR_HISTORY=str(directory / 'history.db'))
    config_args = ['--config', str(args.config.resolve())] if args.config else ['--no-config']
    if args.reload:
        config = directory / 'config.lua'
        config.write_text('return { api_version = 2, gui = { cursor = { blink = false } } }\n')
        config_args = ['--config', str(config)]
        env['TELAR_GUI_RELOAD_CONFIG'] = str(config)
    if args.capture:
        env['TELAR_GUI_CAPTURE'] = str(directory / 'appearance.png')
    subprocess.run([str(binary), 'server', '--background', '--no-config'], env=env,
                   cwd=directory, check=True)
    try:
        with (directory / 'gui.log').open('w') as log:
            subprocess.run([str(binary), 'gui', *config_args, '/bin/sh'],
                           env=dict(env, DYLD_INSERT_LIBRARIES=str(library)), cwd=directory,
                           stdout=log, stderr=log, timeout=50 if args.reload else 20, check=True)
        if args.reload:
            probe = json.loads((directory / 'reload.json').read_text())
            if probe['failed']:
                raise RuntimeError(f'hot reload verification failed: {probe}')
        before = (directory / 'before').read_text().strip()
        after = (directory / 'after').read_text().strip()
        pid = int((directory / 'child.pid').read_text())
        os.kill(pid, 0)
        result = dict(before=before, after=after, shell_pid=pid, shell_survived=True,
                      input_ok=(directory / 'typed').read_text() == 'input-ok')
        if before == after or not result['input_ok']:
            raise RuntimeError(f'lifecycle verification failed: {result}')
        if args.reload:
            result['reload'] = probe
            result['reload']['font_size'] = (directory / 'font-size').read_text().strip()
            result['reload']['window_sizes'] = {
                name: (directory / (name + '-size')).read_text().strip()
                for name in ('hidden-titlebar', 'stronger-blur', 'restored-titlebar')
            }
            if (result['reload']['font_size'] == before or
                    (directory / 'invalid-size').read_text().strip() != result['reload']['font_size'] or
                    int((directory / 'after.pid').read_text()) != pid):
                raise RuntimeError(f'hot reload verification failed: {result}')
        (directory / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2))
    finally:
        subprocess.run([str(binary), 'server', 'stop'], env=env,
                       stdout=subprocess.DEVNULL, timeout=10, check=False)


if __name__ == '__main__':
    main()
