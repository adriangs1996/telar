#!/usr/bin/env python3
"""Capture the native command history against an isolated macOS runtime.

The fixture commands are harmless: some are typed into a throwaway shell and
the rest come from `history_fixture.py` through `telar history import`, so
nothing reads the user's own history. `--frames` takes the pictures from the frames
the window presented (`gui_capture.m`) instead of `screencapture`, which needs
the screen recording permission. A window manager that tiles the window
ignores `--size`; `--font-size` then shrinks the window in logical pixels,
which is what the layout measures.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).parent))
from gui_multiplexer import Actions, exercise  # noqa: E402
from history_fixture import histfile  # noqa: E402

RETURN = 36
ESCAPE = 53
BACKSPACE = 51
SLASH = 44
KEY_O = 31
UP = 126
CAPTURES = ['history-list', 'history-long', 'history-multiline', 'history-script', 'history-click',
            'history-inspector', 'history-failed', 'history-search']
PROOF_LINES = ['argument-24', 'argument-23', 'argument-22']


def long_command(proof):
    """A command longer than any row; each run appends three lines to `proof`."""
    return ("printf '%s\\n' " + ' '.join(f'argument-{index:02d}' for index in range(1, 25)) +
            f' | sort -r | head -n 3 >> {proof}')


def build(source, output):
    subprocess.run(['clang', '-dynamiclib', '-fobjc-arc', '-framework', 'AppKit', '-framework', 'Metal',
                    '-framework', 'QuartzCore', str(Path(__file__).with_name(source)), '-o', str(output)],
                   check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('directory', type=Path, help='new short /tmp directory')
    parser.add_argument('--size', default='1180x720', help='window content size in points')
    parser.add_argument('--frames', action='store_true', help='capture presented frames, not the screen')
    parser.add_argument('--font-size', type=float, help='gui.font.size; larger means a logically smaller window')
    args = parser.parse_args()
    binary = args.binary.resolve()
    directory = args.directory.resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    library = directory / 'driver.dylib'
    build('gui_actions.m', library)
    env = {key: value for key, value in os.environ.items() if not key.startswith('TELAR_')}
    env.update(TELAR_SOCKET=str(directory / 'runtime.sock'), TELAR_HISTORY=str(directory / 'history.db'))
    injected = str(library)
    if args.frames:
        build('gui_capture.m', directory / 'capture.dylib')
        (directory / 'frames').mkdir()
        injected += f":{directory / 'capture.dylib'}"
    gui_args = ('--no-config',)
    if args.font_size:
        (directory / 'gui.lua').write_text(
            'return require("telar").config({ api_version = 2, gui = { font = { size = %g } } })\n' % args.font_size)
        gui_args = ('--config', str(directory / 'gui.lua'))
    subprocess.run([str(binary), 'server', '--background', '--no-config'], env=env, cwd=directory, check=True)
    try:
        (directory / 'fixture.zsh_history').write_text(histfile(int(time.time())))
        subprocess.run([str(binary), 'history', 'import', 'zsh', '--file', str(directory / 'fixture.zsh_history')],
                       env=env, cwd=directory, check=True)
        actions = Actions(directory)
        proof = directory / 'proof'
        long = long_command(proof)
        commands = ['ls /', 'false', long, 'sleep 1', 'echo done']

        def capture(name):
            # A frame is written once the window has been quiet for a moment.
            if args.frames:
                actions.items.extend([{}] * 4)
                actions.items.append(dict(signal=str(directory / f'{name}.at')))
            else:
                actions.capture(name)

        actions.items.append(dict(activate=True, resize=[int(side) for side in args.size.split('x')]))
        actions.items.extend([{}] * 4)
        actions.rename('W', 'telar')
        # Commands in the shell so the page has rows of every status and length.
        for command in commands:
            # Each command finishes before the next is typed, so all are captured.
            actions.text(command)
            actions.key('\r', RETURN)
            actions.items.extend([{}] * 10)
        actions.items.extend([{}] * 4)
        actions.record('initial')
        actions.prefix('/', SLASH)
        actions.items.extend([{}] * 10)
        capture('history-list')
        # Up walks to older commands: the typed long one, then the newest of
        # the imported fixture: Unicode, a multi-line loop and a long script.
        for name, steps in [('history-long', commands[::-1].index(long)), ('history-multiline', 4),
                            ('history-script', 1)]:
            for _ in range(steps):
                actions.key('\uf700', UP)
                actions.items.extend([{}] * 2)
            actions.items.extend([{}] * 6)
            capture(name)
        # A click selects a row without pasting it; its details show its output.
        actions.items.append(dict(click_label='ls /'))
        actions.items.extend([{}] * 6)
        capture('history-click')
        actions.key('o', KEY_O, ctrl=True)
        actions.items.extend([{}] * 10)
        capture('history-inspector')
        actions.key('\x1b', ESCAPE)
        actions.items.extend([{}] * 4)
        actions.text('!')
        actions.items.extend([{}] * 10)
        capture('history-failed')
        actions.key('\x7f', BACKSPACE)
        actions.text('ec')
        actions.items.extend([{}] * 10)
        capture('history-search')
        actions.key('\x1b', ESCAPE)
        actions.items.extend([{}] * 4)
        # The long command runs from the history, then is pasted and run by
        # hand: either way the shell must receive all of it.
        for paste in [False, True]:
            actions.prefix('/', SLASH)
            actions.items.extend([{}] * 6)
            actions.text(PROOF_LINES[0])
            actions.items.extend([{}] * 8)
            actions.key('\r', RETURN, shift=not paste)
            actions.items.extend([{}] * 4)
            if paste:
                actions.key('\r', RETURN)
            actions.items.extend([{}] * 8)
        actions.record('closed')
        exercise(binary, directory, dict(env, TELAR_GUI_CAPTURE_DIR=str(directory / 'frames')), injected, actions,
                 'history', gui_args)
        if args.frames:
            frames = sorted((directory / 'frames').glob('frame-*.png'), key=lambda path: path.stat().st_mtime)
            for name in CAPTURES:
                at = (directory / f'{name}.at').stat().st_mtime
                shown = [frame for frame in frames if frame.stat().st_mtime <= at]
                assert shown, f'no frame was presented before {name}'
                shutil.copyfile(shown[-1], directory / f'{name}.png')
        for name in CAPTURES:
            assert (directory / f'{name}.png').exists(), name
        assert proof.read_text().split() == PROOF_LINES * 3, 'typed, run and pasted must each run the whole command'
        read = lambda name: tuple(map(int, (directory / name).read_text().split()))  # noqa: E731
        assert read('initial') == read('closed'), 'history must leave the shell and its size alone'
        print(directory)
    finally:
        subprocess.run([str(binary), 'server', 'stop'], env=env, stdout=subprocess.DEVNULL,
                       timeout=10, check=False)


if __name__ == '__main__':
    main()
