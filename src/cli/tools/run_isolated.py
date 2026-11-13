#!/usr/bin/env python3
"""Run a check with private HOME/XDG/temp/socket paths and no inherited TELAR context."""
import argparse
from pathlib import Path
import subprocess
import resource
import tempfile
from check_machines_launch import environment


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command and args.command[0] == '--' else args.command
    if not command:
        parser.error('a command is required')
    # runtime-tests deliberately duplicates a descriptor above 4096.
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    descriptor_limit = 8192
    if soft < descriptor_limit and (hard == resource.RLIM_INFINITY or hard >= descriptor_limit):
        resource.setrlimit(resource.RLIMIT_NOFILE, (descriptor_limit, hard))
    with tempfile.TemporaryDirectory(prefix='telar-check-', dir='/tmp') as temporary:
        root = Path(temporary).resolve()
        return subprocess.run(command, env=environment(root)).returncode


if __name__ == '__main__':
    raise SystemExit(main())
