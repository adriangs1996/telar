"""Deterministic, stationary scrollback corpus for native wheel qualification."""

import argparse
import hashlib
from pathlib import Path

from tab_switch_packet import ANCHOR_RGB, MARKER_COLUMN, marker, nibbles
from terminal_bench_fixture import Fixture, atomic_json, write_all

CORPUS_ROWS = 4096
ROWS_PER_INPUT = 3


def corpus_row(identity, columns):
    if (type(identity) is not int or not 1 <= identity <= CORPUS_ROWS or
            type(columns) is not int or not 48 <= columns <= 2000):
        raise ValueError('invalid scroll corpus geometry or identity')
    colors = [ANCHOR_RGB] + [(8 + 16 * value,) * 3 for value in nibbles(0, identity)]
    packet = b''.join(f'\x1b[48;2;{r};{g};{b}m '.encode() for r, g, b in colors)
    remaining = columns - 1 - (MARKER_COLUMN - 1) - len(colors)
    label = f' row {identity:04d} abcdefghijklmnopqrstuvwxyz 0123456789 '.encode()
    body = (label * (remaining // len(label) + 1))[:remaining]
    return b' ' * (MARKER_COLUMN - 1) + packet + b'\x1b[0m' + body


def corpus(columns):
    return b'\r\n'.join(corpus_row(index, columns) for index in range(1, CORPUS_ROWS + 1))


class ScrollFixture(Fixture):
    def __init__(self, directory):
        self.loaded = False
        super().__init__(directory)
        if not self.primary or self.background != 'idle' or self.throughput:
            raise ValueError('scroll fixture requires one idle primary pane')

    def refresh_size(self, *signal_args):
        previous = self.size
        super().refresh_size(*signal_args)
        if self.loaded and self.size != previous:
            raise RuntimeError('scroll corpus geometry changed after population')

    def draw_marker(self):
        if not self.loaded:
            write_all(marker(0, 1))

    def populate(self):
        if self.loaded:
            raise RuntimeError('scroll corpus must only be populated once')
        payload = corpus(self.size.columns)
        self.phase = 'populating'
        self.record()
        write_all(b'\x1b[?25l\x1b[0m\x1b[3J\x1b[2J\x1b[H' + payload + b'\x1b[H\x1b[6n')
        self.await_dsr()
        self.loaded = True
        atomic_json(self.directory / 'scroll.json', dict(
            version=1, pid=self.pid, corpus_rows=CORPUS_ROWS,
            cols=self.size.columns, rows=self.size.lines,
            initial_top_row=CORPUS_ROWS - self.size.lines + 1,
            rows_per_input=ROWS_PER_INPUT, payload_sha256=hashlib.sha256(payload).hexdigest(),
            payload_bytes=len(payload), geometry_generation=self.geometry_generation,
            phase='ready', scope='Stationary ASCII corpus; no continuous production or selection workload.'))
        self.phase = 'ready'
        self.record()

    def handle_marker_input(self, key):
        if key == b'r':
            self.populate()
            return True
        if key == b'c' and self.loaded:
            # Capture precedes upward-only input, which never revisits this row.
            write_all(f'\x1b[1;{MARKER_COLUMN}H\x1b[48;2;180;180;180m \x1b[0m\x1b[H'.encode())
            return True
        if key == b'x':
            raise RuntimeError('typing input reached a wheel-only fixture')
        return False


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    ScrollFixture(parser.parse_args().directory.resolve()).run()
