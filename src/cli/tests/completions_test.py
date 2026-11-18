#!/usr/bin/env python3
"""`telar completions check`: a spec the runtime would skip fails here first."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile


def check(binary, root):
    env = {key: value for key, value in os.environ.items() if not key.startswith('TELAR_')}

    def run(name, source):
        path = root / name
        path.write_text(source)
        return subprocess.run([str(binary), 'completions', 'check', str(path)], env=env, capture_output=True, timeout=10)

    valid = run('nmap.ebnf', 'nmap = { "-v" : "Verbose output" } , [ @file ] ;\n')
    assert valid.returncode == 0, valid
    broken = run('broken.ebnf', 'broken = { "-v" : "Verbose output" , ;\n')
    assert broken.returncode == 1 and broken.stderr, broken
    # The runtime loads a spec only from a file named after its command.
    misnamed = run('nmap.txt', 'nmap = { "-v" : "Verbose output" } ;\n')
    assert misnamed.returncode == 1 and misnamed.stderr, misnamed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--telar', type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='telar-completions-') as directory:
        check(args.telar.resolve(), Path(directory))
    print('completions check CLI cases passed')


if __name__ == '__main__':
    main()
