#!/usr/bin/env python3
"""Capture the sidebar cards with sheet provider marks and a workspace favicon against an isolated macOS runtime.

Three tiny C programs named claude, codex and pi stand in for the agents: the
runtime identifies the foreground process by its command name once it
produces output, so each fake agent prints a line per second. (A renamed
copy of a platform binary is killed by macOS, so they are compiled here.) The workspace
root carries a generated favicon.png so the card's project slot shows it once
the favicon worker has landed it.
"""
import argparse
import os
from pathlib import Path
import struct
import subprocess
import sys
import zlib

sys.path.insert(0, str(Path(__file__).parent))
from gui_multiplexer import Actions, exercise  # noqa: E402


def png(width, height, rgba_of):
    """A minimal RGBA8 PNG so the capture needs no image library."""
    def chunk(kind, data):
        body = kind + data
        return struct.pack('>I', len(data)) + body + struct.pack('>I', zlib.crc32(body) & 0xffffffff)
    rows = b''.join(b'\0' + b''.join(bytes(rgba_of(x, y)) for x in range(width)) for y in range(height))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


def favicon(x, y):
    # An orange disc with a transparent corner background: alpha proves the premultiplied path.
    inside = (x - 15.5) ** 2 + (y - 15.5) ** 2 <= 14 ** 2
    return (255, 140, 0, 255) if inside else (0, 0, 0, 0)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('directory', type=Path, help='new short /tmp directory')
    args = parser.parse_args()
    binary = args.binary.resolve()
    directory = args.directory.resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    (directory / 'favicon.png').write_bytes(png(32, 32, favicon))
    (directory / 'agent.c').write_text(
        '#include <stdio.h>\n#include <unistd.h>\n'
        'int main(int argc, char **argv) { for (;;) { printf("working on %s\\n", argv[0]); fflush(stdout); sleep(1); } }\n')
    for provider in ('claude', 'codex', 'pi'):
        subprocess.run(['clang', str(directory / 'agent.c'), '-o', str(directory / provider)], check=True)
    library = directory / 'driver.dylib'
    subprocess.run(['clang', '-dynamiclib', '-fobjc-arc', '-framework', 'AppKit',
                    str(Path(__file__).with_name('gui_actions.m')), '-o', str(library)], check=True)
    env = {key: value for key, value in os.environ.items() if not key.startswith('TELAR_')}
    env.update(TELAR_SOCKET=str(directory / 'runtime.sock'), TELAR_HISTORY=str(directory / 'history.db'))
    subprocess.run([str(binary), 'server', '--background', '--no-config'], env=env, cwd=directory, check=True)
    try:
        actions = Actions(directory)
        actions.rename('W', 'telar')
        actions.record('initial')
        splits = {'claude': None, 'codex': ('%', 22), 'pi': ('"', 39)}
        for provider, split in splits.items():
            if split is not None:
                actions.prefix(split[0], split[1], shift=True)
                actions.items.extend([{}] * 6)
            actions.text(f'./{provider}')
            actions.key('\r', 36)
            actions.items.extend([{}] * 16)
        actions.items.extend([{}] * 20)
        actions.capture('slice-8-cards')
        exercise(binary, directory, env, library, actions, 'sprites')
        assert (directory / 'slice-8-cards.png').exists()
        print((directory / 'slice-8-cards.png'))
    finally:
        subprocess.run([str(binary), 'server', 'stop'], env=env, stdout=subprocess.DEVNULL,
                       timeout=10, check=False)


if __name__ == '__main__':
    main()
