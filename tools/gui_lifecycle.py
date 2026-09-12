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
    args = parser.parse_args()
    binary = args.binary.resolve()
    directory = args.directory.resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    library = directory / 'driver.dylib'
    subprocess.run(['clang', '-dynamiclib', '-fobjc-arc', '-framework', 'AppKit',
                    str(Path(__file__).with_suffix('.m')), '-o', str(library)], check=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith('TELAR_')}
    env.update(TELAR_SOCKET=str(directory / 'runtime.sock'),
               TELAR_HISTORY=str(directory / 'history.db'))
    subprocess.run([str(binary), 'server', '--background', '--no-config'], env=env,
                   cwd=directory, check=True)
    try:
        with (directory / 'gui.log').open('w') as log:
            subprocess.run([str(binary), 'gui', '--no-config', '/bin/sh'],
                           env=dict(env, DYLD_INSERT_LIBRARIES=str(library)), cwd=directory,
                           stdout=log, stderr=log, timeout=20, check=True)
        before = (directory / 'before').read_text().strip()
        after = (directory / 'after').read_text().strip()
        pid = int((directory / 'child.pid').read_text())
        os.kill(pid, 0)
        result = dict(before=before, after=after, shell_pid=pid, shell_survived=True,
                      input_ok=(directory / 'typed').read_text() == 'input-ok')
        if before == after or not result['input_ok']:
            raise RuntimeError(f'lifecycle verification failed: {result}')
        (directory / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2))
    finally:
        subprocess.run([str(binary), 'server', 'stop'], env=env,
                       stdout=subprocess.DEVNULL, timeout=10, check=False)


if __name__ == '__main__':
    main()
