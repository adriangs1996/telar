#!/usr/bin/env python3
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from check_machines_launch import environment


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--telar', type=Path, required=True)
    args = parser.parse_args()
    original = args.telar.resolve()
    with tempfile.TemporaryDirectory(prefix='telar-loader-', dir='/tmp') as temporary:
        root = Path(temporary).resolve()
        env = environment(root)
        program = root / 'telar'
        shutil.copy2(original, program)
        def run(words, data=b''):
            return subprocess.run([str(program), *words], env=env, input=data, capture_output=True, timeout=10)
        for words in [['--version'], ['machine', 'list', '--help'], ['hook', 'claude', '--socket', str(root/'missing.sock')]]:
            result = run(words, b'{"hook_event_name":"SessionStart"}')
            assert result.returncode == 0, result
        result = run(['machine', 'list'])
        assert result.returncode == 1 and b'Cannot load telar-launch.so beside telar' in result.stderr, result
        shutil.copy2(original.parent/'telar-launch.so', root/'telar-launch.so')
        result = run(['machine', 'list', '--json'])
        assert result.returncode == 0 and b'"machines":[]' in result.stdout, result
        link = root/'linked';link.mkdir();(link/'telar').symlink_to(program)
        result = subprocess.run([str(link/'telar'), 'machine', 'list', '--json'], env=env, capture_output=True, timeout=10)
        assert result.returncode == 0 and b'"machines":[]' in result.stdout, result
    print('Hook/help independence, missing module refusal and symlink resolution passed')


if __name__ == '__main__':
    main()
