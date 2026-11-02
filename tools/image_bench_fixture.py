#!/usr/bin/env python3
"""Closed-loop Kitty image replacement for the native presented-pixel probe.

Each input replaces image 77 through shared memory. The image itself supplies
the alternating marker; no text marker can satisfy the image endpoint.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import sys
import time

import _posixshmem

from kitty_stream import publish
from terminal_bench_fixture import Fixture, atomic_json, defer_resize


CHANNELS = 4
MAX_IMAGE_BYTES = 64 * 1024 * 1024
MAX_PUBLICATIONS = 1024
COLORS = ((230, 20, 60, 255), (20, 220, 200, 255), (180, 180, 180, 255))


def image_extent(width, height):
    if min(width, height) <= 0 or width * height * CHANNELS > MAX_IMAGE_BYTES:
        raise ValueError('image dimensions must be positive and fit 64 MiB of RGBA')
    return width, height


class ImageFixture(Fixture):
    def __init__(self, directory, size):
        self.image_size = image_extent(*size)
        self.frames = tuple(bytes(color) * (size[0] * size[1]) for color in COLORS)
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
            name = f'{self.shared_prefix}-{len(self.publications):x}'
            self.shared_names.append(name)
            started = time.monotonic_ns()
            publish(sys.stdout.buffer, name, self.frames[color], self.image_size)
            self.publications.append(dict(generation=len(self.publications) + 1, color=color,
                                          input_sequence=self.marker_inputs,
                                          started_ns=started, written_ns=time.monotonic_ns()))

    def record(self):
        with defer_resize():
            super().record()
            receipt = json.loads(self.receipt.read_text())
            receipt['image'] = dict(width=self.image_size[0], height=self.image_size[1],
                                    format='RGBA8888', transport='kitty-shared-memory',
                                    bytes_per_image=len(self.frames[0]), payload_sha256=self.digests,
                                    workload='closed-loop replacement on input',
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
    args = parser.parse_args()
    try:
        size = image_extent(args.width, args.height)
    except ValueError as error:
        parser.error(str(error))
    ImageFixture(args.directory.resolve(), size).run()


if __name__ == '__main__':
    main()
