#!/usr/bin/env python3
"""`telar render` output: the document zone the window parses, and what reaches the terminal."""
import argparse
import os
from pathlib import Path
import pty
import re
import select
import subprocess
import tempfile
import termios
import time

BEGIN = b'\x1b]7780;begin;'
END = b'\x1b]7780;end\x1b\\'
# render.max_markdown_bytes, lib/render/markdown/markdown.cppm.
MAX_SOURCE_BYTES = 4 << 20


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


def read_terminal(leader, until, deadline):
    output = b''
    while until(output) and time.monotonic() < deadline:
        if select.select([leader], [], [], .05)[0]:
            try:
                part = os.read(leader, 65536)
            except OSError:
                break
            if not part:
                break
            output += part
    return output


def on_terminal(words, env, stdin=None):
    """Runs `words` with stdout on a new terminal; returns its status and what the terminal got."""
    leader, follower = pty.openpty()
    try:
        process = subprocess.Popen(words, env=env, stdin=stdin, stdout=follower, stderr=subprocess.PIPE)
        output = read_terminal(leader, lambda _: process.poll() is None, time.monotonic() + 10)
        process.wait(timeout=10)
        output += read_terminal(leader, lambda _: True, time.monotonic() + .2)
    finally:
        os.close(follower)
        os.close(leader)
    return process.returncode, output


def automatic_format(binary, root, env):
    """By default the document zone goes only to a pane's terminal: output redirected to a
    file, or a terminal outside telar, gets the styled text alone."""
    source = root / 'automatic.md'
    source.write_text('# Title\n\nText.\n')
    words = [str(binary), 'render', 'markdown', str(source)]
    pane = env | {'TELAR_PANE_ID': '1'}
    status, output = on_terminal(words, pane)
    assert status == 0 and BEGIN in output and b'\x1b]7780;end' in output, output
    piped = subprocess.run(words, env=pane, capture_output=True, timeout=10)
    assert piped.returncode == 0 and b'Title' in piped.stdout and b'\x1b]7780;' not in piped.stdout, piped
    status, output = on_terminal(words, env)
    assert status == 0 and b'Title' in output and b'\x1b]7780;' not in output, output


def source_size_limit(binary, env):
    """A source over render.max_markdown_bytes is refused whole rather than rendered cut;
    one of exactly that size renders."""
    words = [str(binary), 'render', 'markdown', '--format', 'ansi', '--width', '80']
    paragraph = b'word '
    largest = (paragraph * (MAX_SOURCE_BYTES // len(paragraph) + 1))[:MAX_SOURCE_BYTES]
    over = subprocess.run(words, input=largest + b'x', env=env, capture_output=True, timeout=20)
    assert over.returncode == 1 and over.stdout == b'', (over.returncode, over.stdout[:200], over.stderr)
    exact = subprocess.run(words, input=largest, env=env, capture_output=True, timeout=20)
    assert exact.returncode == 0 and exact.stdout, (exact.returncode, exact.stderr)


def width_option(binary, env):
    """--width wraps the text to that many columns, whatever the terminal's width."""
    text = b'Some words here that go on and on for quite a while, so that a line of thirty columns cannot hold them all.\n'
    result = subprocess.run([str(binary), 'render', 'markdown', '--width', '30', '--format', 'ansi'], input=text, env=env, capture_output=True, timeout=10)
    assert result.returncode == 0, result
    visible = re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', result.stdout.decode())
    lines = [line for line in visible.split('\n') if line.strip()]
    assert len(lines) > 1 and all(len(line) <= 30 for line in lines), visible


def pager_keys(binary, root, env):
    """In the pager, q, a lone Escape, Ctrl-C and Ctrl-D quit and give the shell its terminal
    back: echo and line editing on, the primary screen restored. An arrow key does not quit."""
    source = root / 'pager.md'
    source.write_text('# Title\n')
    # The shell that started the pager reads the terminal's modes once it quits.
    script = '"$@"; status=$?; stty -a; echo "status=$status"'
    for keys in [b'q', b'\x1b', b'\x03', b'\x04', b'\x1b[A']:
        pid, leader = pty.fork()
        if pid == 0:
            os.execve('/bin/sh', ['/bin/sh', '-c', script, 'sh', str(binary), 'render', 'markdown', str(source), '--pager', '--format', 'native'],
                      env | {'TELAR_PANE_ID': '1'})
        try:
            deadline = time.monotonic() + 10
            output = read_terminal(leader, lambda seen: b'q to quit' not in seen, deadline)
            assert b'q to quit' in output, output
            os.write(leader, keys)
            if keys == b'\x1b[A':
                output += read_terminal(leader, lambda _: True, time.monotonic() + .5)
                assert b'status=' not in output, (keys, output)
                os.write(leader, b'q')
            output += read_terminal(leader, lambda seen: b'status=' not in seen, deadline)
        finally:
            _, status = os.waitpid(pid, 0)
            os.close(leader)
        modes = output[output.rfind(b'\x1b[?1049l'):].split()
        assert os.waitstatus_to_exitcode(status) == 0 and b'status=0' in output, (keys, output)
        assert output.rfind(b'\x1b[?1049l') > output.find(b'\x1b[?1049h') >= 0, (keys, output)
        assert b'echo' in modes and b'icanon' in modes, (keys, output)

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
        automatic_format(args.telar.resolve(), root, env)
        source_size_limit(args.telar.resolve(), env)
        width_option(args.telar.resolve(), env)
        pager_keys(args.telar.resolve(), root, env)
    print('6 render CLI cases passed')


if __name__ == '__main__':
    main()
