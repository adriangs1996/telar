#!/usr/bin/env python3
"""Streams synthetic RGBA frames over the Kitty graphics protocol's shared
memory transport (t=s) inside the atomic envelope the runtime folds.

Each frame is one POSIX shared-memory object the terminal adopts and unlinks.
The cursor is saved and restored around every frame so a program sharing the
pane (the latency probe's cat) keeps its own position. Frames alternate
between two contents, so every generation changes what the window draws.
"""
import argparse
import base64
import mmap
import os
import sys
import time

import _posixshmem


def frame_bytes(width, height, shade):
    row = bytes((x * 255 // max(1, width - 1), shade, 255 - shade, 255)[c] for x in range(width) for c in range(4))
    return row * height


def publish(out, name, pixels, size):
    fd = _posixshmem.shm_open(name, os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o600)
    try:
        os.ftruncate(fd, len(pixels))
        with mmap.mmap(fd, len(pixels)) as mapping:
            mapping[:] = pixels
    finally:
        os.close(fd)
    encoded = base64.standard_b64encode(name.encode()).decode()
    width, height = size
    out.write(("\0337\033[?2026h\033[H\033_Ga=T,f=32,s=%d,v=%d,t=s,i=77,p=1,C=1,q=2;%s\033\\\033[?2026l\0338"
               % (width, height, encoded)).encode())
    out.flush()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--width', type=int, default=3840)
    parser.add_argument('--height', type=int, default=2160)
    parser.add_argument('--fps', type=float, default=120.0)
    parser.add_argument('--seconds', type=float, default=30.0)
    parser.add_argument('--report', help='file that receives the frames published and elapsed seconds')
    parser.add_argument('--text', action='store_true',
                        help='redraw a counter at the same rate instead of images: the control that separates the '
                             'cost of redrawing from the cost of images')
    args = parser.parse_args()
    frames = [] if args.text else [frame_bytes(args.width, args.height, shade) for shade in (40, 200)]
    out = sys.stdout.buffer
    interval = 1.0 / args.fps
    started = time.monotonic()
    published = 0
    deadline = started
    while time.monotonic() - started < args.seconds:
        if args.text:
            out.write(("\0337\033[?2026h\033[20;1H%08d\033[?2026l\0338" % published).encode())
            out.flush()
        else:
            name = '/tkg-%d-%d' % (os.getpid(), published)
            publish(out, name, frames[published & 1], (args.width, args.height))
        published += 1
        deadline += interval
        pause = deadline - time.monotonic()
        if pause > 0:
            time.sleep(pause)
        else:
            deadline = time.monotonic()
    if args.report:
        with open(args.report, 'w') as report:
            report.write('%d %.3f\n' % (published, time.monotonic() - started))


if __name__ == '__main__':
    main()
