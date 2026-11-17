#!/usr/bin/env python3
"""`telar render` output: the document zone the window parses, and what reaches the terminal."""
import argparse
import os
from pathlib import Path
import pty
import select
import subprocess
import tempfile
import time

BEGIN = b'\x1b]7780;begin;'
END = b'\x1b]7780;end\x1b\\'


def environment(root):
    result = {k: v for k, v in os.environ.items() if not k.startswith('TELAR_')}
    for key in ('HOME', 'XDG_RUNTIME_DIR', 'XDG_DATA_HOME', 'XDG_CONFIG_HOME', 'XDG_STATE_HOME', 'TMPDIR'):
        path = root / key.lower()
        path.mkdir(parents=True, exist_ok=True)
        result[key] = str(path)
    return result


def document_zone(binary, root, env):
    """The styled text sits inside the zone: a lost or early end leaves the zone open over
    the pane's later output."""
    source = root / 'document.md'
    source.write_text('# Title\n\nSome *styled* text and a [link](https://example.invalid).\n\n- one\n- two\n')
    words = [str(binary), 'render', 'markdown', str(source), '--width', '40', '--format']
    native = subprocess.run(words + ['native'], env=env, capture_output=True, timeout=10)
    ansi = subprocess.run(words + ['ansi'], env=env, capture_output=True, timeout=10)
    assert native.returncode == 0 and ansi.returncode == 0, (native, ansi)
    assert native.stdout.startswith(BEGIN) and native.stdout.endswith(END), native.stdout
    opened = native.stdout.index(b'\x1b\\') + 2
    assert native.stdout[opened:-len(END)] == ansi.stdout and b'Title' in ansi.stdout, native.stdout
    assert b'\x1b]7780;' not in ansi.stdout, ansi.stdout


def pager_title(binary, root, env):
    """The file name reaches the terminal in the pager's status line without its control
    bytes, so a crafted name cannot inject escape sequences."""
    name = 'a\x1b]0;pwned\x07b\x7fc.md'
    (root / name).write_text('# Title\n')
    pid, leader = pty.fork()
    if pid == 0:
        os.chdir(root)
        os.execve(str(binary), [str(binary), 'render', 'markdown', name, '--pager', '--format', 'native'], env | {'TELAR_PANE_ID': '1'})
    output = b''
    deadline = time.monotonic() + 10
    try:
        while b'q to quit' not in output:
            assert time.monotonic() < deadline, output
            if select.select([leader], [], [], .1)[0]:
                output += os.read(leader, 65536)
        os.write(leader, b'q')
        while time.monotonic() < deadline:
            if not select.select([leader], [], [], .1)[0]:
                continue
            try:
                part = os.read(leader, 65536)
            except OSError:
                break
            if not part:
                break
            output += part
    finally:
        _, status = os.waitpid(pid, 0)
        os.close(leader)
    assert os.waitstatus_to_exitcode(status) == 0, (status, output)
    assert 'telar render · a]0;pwnedbc.md · q to quit'.encode() in output, output
    assert b'\x1b]0;' not in output and b'\x07' not in output and b'\x7f' not in output, output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--telar', type=Path, required=True)
    parser.add_argument('--scratch', type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='render-', dir=args.scratch) as directory:
        root = Path(directory).resolve()
        env = environment(root)
        document_zone(args.telar.resolve(), root, env)
        pager_title(args.telar.resolve(), root, env)
    print('2 render CLI cases passed')


if __name__ == '__main__':
    main()
