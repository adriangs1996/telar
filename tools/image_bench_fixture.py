#!/usr/bin/env python3
"""Closed-loop Kitty image replacement for the native presented-pixel probe.

Each input replaces image 77 through shared memory or chunked inline data. The image itself supplies
the alternating marker; no text marker can satisfy the image endpoint.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import sys
import time

import _posixshmem

import image_patterns
from image_patterns import COLORS
from kitty_stream import publish
from terminal_bench_fixture import Fixture, atomic_json, defer_resize


CHANNELS = 4
MAX_IMAGE_BYTES = 64 * 1024 * 1024
MAX_PUBLICATIONS = 1024
INLINE_CHUNK_BYTES = 4096
TRANSPORTS = ('shared-memory', 'inline')


def inline_frame(pixels, size, cells):
    encoded = base64.standard_b64encode(pixels)
    placement = '' if cells is None else ',c=%d,r=%d' % tuple(cells)
    header = ('a=T,f=32,s=%d,v=%d,t=d,i=77,p=1,C=1,q=2%s,' % (*size, placement)).encode()
    commands = [b'\x1b7\x1b[?2026h\x1b[H']
    for offset in range(0, len(encoded), INLINE_CHUNK_BYTES):
        end = min(offset + INLINE_CHUNK_BYTES, len(encoded))
        more = b'1' if end < len(encoded) else b'0'
        commands.append(b'\x1b_G' + (header if offset == 0 else b'') + b'm=' + more + b';' + encoded[offset:end] + b'\x1b\\')
    commands.append(b'\x1b[?2026l\x1b8')
    return b''.join(commands)


def image_extent(width, height):
    if min(width, height) <= 0 or width * height * CHANNELS > MAX_IMAGE_BYTES:
        raise ValueError('image dimensions must be positive and fit 64 MiB of RGBA')
    return width, height


class ImageFixture(Fixture):
    def __init__(self, directory, size, pattern='opaque', transport='shared-memory'):
        if transport not in TRANSPORTS:
            raise ValueError('unknown image transport')
        self.transport = transport
        self.image_size = image_extent(*size)
        self.pattern = pattern
        self.cells = image_patterns.placement(size, pattern)
        self.frames = image_patterns.frames(size, pattern)
        self.inline_frames = [inline_frame(frame, size, self.cells) for frame in self.frames] if transport == 'inline' else None
        self.digests = [hashlib.sha256(frame).hexdigest() for frame in self.frames]
        self.shared_names = []
        self.shared_prefix = '/tbi-' + secrets.token_hex(6)
        self.publications = []
        super().__init__(directory)
        if not self.primary or self.throughput or self.background != 'idle':
            raise ValueError('image fixture requires one idle primary pane without throughput')

    def draw_marker(self):
        with defer_resize():
            if len(self.publications) >= MAX_PUBLICATIONS:
                raise RuntimeError('image fixture exceeded its bounded publication count')
            color = 2 if self.capture_marker else self.color
            started = time.monotonic_ns()
            if self.transport == 'inline':
                sys.stdout.buffer.write(self.inline_frames[color])
                sys.stdout.buffer.flush()
            else:
                name = f'{self.shared_prefix}-{len(self.publications):x}'
                self.shared_names.append(name)
                publish(sys.stdout.buffer, name, self.frames[color], self.image_size, self.cells)
            self.publications.append(dict(generation=len(self.publications) + 1, color=color,
                                          input_sequence=self.marker_inputs,
                                          started_ns=started, written_ns=time.monotonic_ns()))

    def record(self):
        with defer_resize():
            super().record()
            receipt = json.loads(self.receipt.read_text())
            receipt['image'] = dict(width=self.image_size[0], height=self.image_size[1],
                                    format='RGBA8888', transport='kitty-' + self.transport,
                                    bytes_per_image=len(self.frames[0]), payload_sha256=self.digests,
                                    workload='closed-loop replacement on input',
                                    pattern=self.pattern, placement_cells=self.cells,
                                    publications=self.publications)
            atomic_json(self.receipt, receipt)

    def close(self):
        names = len(self.shared_names)
        unadopted = []
        for name in self.shared_names:
            try:
                _posixshmem.shm_unlink(name)
                unadopted.append(name)
            except FileNotFoundError:
                pass
        self.shared_names.clear()
        atomic_json(self.directory / 'image-cleanup.json', dict(pid=os.getpid(), names=names,
                                                               unadopted_names=unadopted, complete=True))

    def run(self):
        try:
            super().run()
        finally:
            self.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--width', type=int, required=True)
    parser.add_argument('--height', type=int, required=True)
    parser.add_argument('--pattern', choices=image_patterns.PATTERNS, default='opaque')
    parser.add_argument('--transport', choices=TRANSPORTS, default='shared-memory')
    args = parser.parse_args()
    try:
        size = image_extent(args.width, args.height)
        image_patterns.placement(size, args.pattern)
    except ValueError as error:
        parser.error(str(error))
    ImageFixture(args.directory.resolve(), size, args.pattern, args.transport).run()


if __name__ == '__main__':
    main()
