#!/usr/bin/env python3

import fcntl
from pathlib import Path
import signal
import struct
import sys
import termios
import time

from terminal_bench_fixture import atomic_json


WINDOW_SIZE = struct.Struct("HHHH")


def main():
    destination = Path(sys.argv[1])
    revision = 0

    def record(*_):
        nonlocal revision
        dimensions = fcntl.ioctl(0, termios.TIOCGWINSZ, bytes(WINDOW_SIZE.size))
        rows, columns, pixel_width, pixel_height = WINDOW_SIZE.unpack(dimensions)
        revision += 1
        atomic_json(destination, dict(revision=revision, changed_at_ns=time.monotonic_ns(),
                                     columns=columns, rows=rows, pixel_width=pixel_width,
                                     pixel_height=pixel_height))

    signal.signal(signal.SIGWINCH, record)
    record()
    while True:
        signal.pause()


if __name__ == "__main__":
    main()
