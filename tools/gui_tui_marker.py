#!/usr/bin/env python3
"""Raw PTY fixture: each key changes one background cell; hide cursor noise."""
import json
import os
import signal
import sys
import termios
import tty


def main():
    original = termios.tcgetattr(0)
    color = 0
    last_size = None

    def draw(*_):
        nonlocal last_size
        size = os.get_terminal_size(0)
        if len(sys.argv) > 1 and size != last_size:
            with open(sys.argv[1], 'w') as file:
                json.dump([size.columns, size.lines], file)
            last_size = size
        rgb = '230;20;60' if color == 0 else '20;220;200'
        os.write(1, (f'\x1b[?25l\x1b[{min(8, size.lines)};{min(20, size.columns)}H'
                     f'\x1b[48;2;{rgb}m \x1b[0m\x1b[H').encode())

    try:
        tty.setraw(0)
        signal.signal(signal.SIGWINCH, draw)
        os.write(1, b'\x1b[2J')
        draw()
        while os.read(0, 1):
            color ^= 1
            draw()
    finally:
        termios.tcsetattr(0, termios.TCSANOW, original)


if __name__ == '__main__':
    main()
