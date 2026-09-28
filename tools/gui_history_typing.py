#!/usr/bin/env python3
"""Trace every native frame while typing into the command history search.

A reply that lands within a frame or two must not dim the rows or show the
loading line: each keystroke would otherwise flash the whole panel.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).parent))
from gui_multiplexer import Actions, exercise  # noqa: E402

RETURN = 36
ESCAPE = 53
SLASH = 44
QUERY = 'echo'
# Any glyph drawn under 60% opacity counts as dim; a row holds more than this.
DIM_TOLERANCE = 4


def flashes(frames, baseline):
    return [frame for frame in frames
            if frame['dim'] > baseline['dim'] + DIM_TOLERANCE or frame['lines'] > baseline['lines']]


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
                    str(Path(__file__).with_name('gui_actions.m')), '-o', str(library)], check=True)
    env = {key: value for key, value in os.environ.items() if not key.startswith('TELAR_')}
    # The marker installs the frame hook; no pane paints it here.
    env.update(TELAR_SOCKET=str(directory / 'runtime.sock'), TELAR_HISTORY=str(directory / 'history.db'),
               TELAR_GUI_MARKER='1,2,3')
    subprocess.run([str(binary), 'server', '--background', '--no-config'], env=env, cwd=directory, check=True)
    try:
        actions = Actions(directory)
        actions.items.append(dict(activate=True, resize=[1180, 720]))
        actions.items.extend([{}] * 4)
        for command in ['ls /', 'false', 'echo one', 'echo two', 'printf done']:
            actions.text(command)
            actions.key('\r', RETURN)
            actions.items.extend([{}] * 4)
        actions.items.extend([{}] * 8)
        actions.prefix('/', SLASH)
        actions.items.extend([{}] * 10)
        actions.items.append(dict(trace_frames=True))
        actions.items.extend([{}] * 4)
        for character in QUERY:
            actions.text(character)
        actions.items.extend([{}] * 4)
        actions.items.append(dict(write_frames=str(directory / 'frames.json')))
        actions.key('\x1b', ESCAPE)
        actions.items.extend([{}] * 4)
        exercise(binary, directory, env, library, actions, 'history-typing')
    finally:
        subprocess.run([str(binary), 'server', 'stop'], env=env, stdout=subprocess.DEVNULL,
                       timeout=10, check=False)

    frames = json.loads((directory / 'frames.json').read_text())['frames']
    assert len(frames) > len(QUERY), 'every keystroke must present at least one frame'
    baseline = frames[0]
    flashed = flashes(frames, baseline)
    print(f'{len(frames)} frames, {len(flashed)} dimmed or loading; baseline {baseline}')
    for frame in flashed:
        print(f"  {frame['time_ms']:8.1f} ms  dim {frame['dim']:4d}  lines {frame['lines']}  glyphs {frame['glyphs']}")
    assert not flashed, 'typing must not flash the history rows'
    print(directory)


if __name__ == '__main__':
    main()
