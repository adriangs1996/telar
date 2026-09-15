#!/usr/bin/env python3
"""Exercise and capture the native context form against an isolated macOS runtime."""
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess

from gui_multiplexer import Actions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('directory', type=Path, help='new short /tmp directory')
    args = parser.parse_args()
    binary = args.binary.resolve()
    directory = args.directory.resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    projects = directory / 'projects'
    for name in ['api', 'dashboard', 'design-system', 'docs', 'mobile', 'platform']:
        (projects / name).mkdir(parents=True)
    library = directory / 'driver.dylib'
    subprocess.run(['clang', '-dynamiclib', '-fobjc-arc', '-framework', 'AppKit',
                    str(Path(__file__).with_name('gui_actions.m')), '-o', str(library)], check=True)
    env = {key: value for key, value in os.environ.items() if not key.startswith('TELAR_')}
    env.update(TELAR_SOCKET=str(directory / 'runtime.sock'), TELAR_HISTORY=str(directory / 'history.db'))
    subprocess.run([str(binary), 'server', '--background', '--no-config'], env=env, cwd=directory, check=True)
    try:
        for theme, size in [('osaka-jade', 15), ('vesper', 22)]:
            config = directory / f'{theme}.lua'
            config.write_text("return { api_version = 2, theme = '%s', gui = { font = { size = %d }, window = { titlebar = false } } }" % (theme, size))
            actions = Actions(directory)
            actions.prefix('N', 45, shift=True)
            actions.items.append(dict(capture_controls=str(directory / f'{theme}-empty.png')))
            actions.text('Payments')
            actions.key('\t', 48)
            actions.text(str(projects) + '/')
            actions.items.extend([{}] * 6)
            actions.items.append(dict(capture_controls=str(directory / f'{theme}-folders.png')))
            actions.items.append(dict(click_label='dashboard'))
            actions.items.extend([{}] * 6)
            actions.items.append(dict(expect_value=dict(label='Working directory', value=str(projects / 'dashboard') + '/')))
            actions.key('a', 0, cmd=True)
            created = directory / f'{theme}-new-project'
            actions.text(str(created))
            actions.items.extend([{}] * 6)
            actions.items.append(dict(click_label='Create context'))
            actions.items.extend([{}] * 4)
            actions.items.append(dict(capture_controls=str(directory / f'{theme}-confirmation.png')))
            actions.items.append(dict(click_label='Create folder & context'))
            actions.items.extend([{}] * 6)
            actions.capture(f'{theme}-created')
            cwd_record = directory / f'{theme}-cwd'
            actions.text(f'pwd > {shlex.quote(str(cwd_record))}')
            actions.key('\r', 36)
            actions.items.append(dict(wait=str(cwd_record)))
            actions.prefix('N', 45, shift=True)
            actions.items.append(dict(click_label='Close new context'))
            actions.items.extend([{}] * 4)
            cancelled = directory / f'{theme}-cancelled'
            actions.text(f'touch {shlex.quote(str(cancelled))}')
            actions.key('\r', 36)
            actions.items.append(dict(wait=str(cancelled)))
            script = directory / f'{theme}.json'
            script.write_text(json.dumps(actions.items))
            with (directory / f'{theme}.log').open('w') as log:
                subprocess.run([str(binary), 'gui', '--config', str(config), '/bin/sh'], cwd=directory,
                               env=dict(env, DYLD_INSERT_LIBRARIES=str(library), TELAR_GUI_ACTIONS=str(script)),
                               stdout=log, stderr=log, timeout=100, check=True)
            assert created.is_dir(), created
            assert Path(cwd_record.read_text().strip()).resolve() == created.resolve()
            assert cancelled.exists(), cancelled
            print(f'{theme}: folder completion, creation, shell cwd and close passed', flush=True)
    finally:
        subprocess.run([str(binary), 'server', 'stop'], env=env, stdout=subprocess.DEVNULL,
                       timeout=10, check=False)


if __name__ == '__main__':
    main()
