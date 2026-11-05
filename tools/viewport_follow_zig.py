#!/usr/bin/env python3
"""Drive the numbered-row fixture using a reference-revision Zig wire adapter.

Used by check_viewport_follow.py --zig-wire. The C++ probe supplies only the
raw PTY child; all reference messages and cells use the actual Zig codecs.
"""

import argparse
import ctypes
import enum
import json
from pathlib import Path
import socket
import struct
import time


COLUMNS, ROWS = 82, 21
INITIAL_LINES, ADDITIONAL_LINES = 100, 25
MAX_PAYLOAD = 4 * 1024 * 1024


class Operation(enum.IntEnum):
    HELLO = 0
    SUBSCRIBE = 1
    OPEN = 2
    VIEWPORT = 3
    INPUT = 4
    ACK = 5
    CLOSE = 6
    READ = 7
    RESIZE = 8
    OPEN_REFLOW = 9


class Event(enum.IntEnum):
    IGNORED = 0
    ACCEPTED = 1
    OPENED = 2
    FRAME = 3
    EXITED = 4
    OUTPUT_COMPLETE = 5
    OUTPUT_PENDING = 6


class Request(ctypes.Structure):
    _fields_ = [('operation', ctypes.c_uint32), ('pane_id', ctypes.c_uint64),
                ('value', ctypes.c_uint64), ('text', ctypes.c_char_p),
                ('extra', ctypes.c_char_p)]


class View(ctypes.Structure):
    _fields_ = [('pane_id', ctypes.c_uint64), ('generation', ctypes.c_uint64),
                ('frame_id', ctypes.c_uint64), ('base_frame_id', ctypes.c_uint64),
                ('total', ctypes.c_uint32), ('offset', ctypes.c_uint32),
                ('columns', ctypes.c_uint16), ('rows', ctypes.c_uint16)]


class Wire:
    def __init__(self, library):
        self.library = ctypes.CDLL(str(library))
        self.library.viewport_encode.argtypes = [ctypes.POINTER(Request), ctypes.c_void_p, ctypes.c_size_t]
        self.library.viewport_encode.restype = ctypes.c_ssize_t
        self.library.viewport_apply.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(View),
                                               ctypes.c_void_p, ctypes.c_size_t]
        self.library.viewport_apply.restype = ctypes.c_int
        self.view = View()
        self.expected_columns = COLUMNS
        self.reflow = False
        self.cells = ctypes.create_string_buffer(COLUMNS * ROWS)
        self.output = ctypes.create_string_buffer(MAX_PAYLOAD)

    def encode(self, operation, value=0, text=b'', extra=b''):
        request = Request(operation, self.view.pane_id, value, text, extra)
        length = self.library.viewport_encode(ctypes.byref(request), self.output, len(self.output))
        if length <= 0:
            raise ValueError('Encoding rejected')
        return self.output.raw[:length]

    def apply(self, payload):
        result = self.library.viewport_apply(payload, len(payload), ctypes.byref(self.view),
                                             self.cells, len(self.cells))
        if result < 0:
            raise ValueError('Frame/handshake decoder rejected payload')
        return Event(result)

    def observation(self):
        view = self.view
        assert (view.columns, view.rows) == (self.expected_columns, ROWS)
        assert view.total >= ROWS and view.offset <= view.total - ROWS
        rows_per_line = 2 if self.reflow and view.columns == COLUMNS // 2 else 1
        def line(row):
            if row == view.total - 1:
                return b''
            text = f'row{row // rows_per_line:06d}'.encode() + (b'x' * 60 if self.reflow else b'')
            start = (row % rows_per_line) * view.columns
            return text[start:start + view.columns]
        expected = b''.join(line(row).ljust(view.columns, b' ') for row in range(view.offset, view.offset + ROWS))
        assert self.cells.raw[:view.columns * ROWS] == expected, 'Visible cells differ from the numbered corpus'
        return dict(total=view.total, offset=view.offset, bottom=view.total - view.rows,
                    frame=view.frame_id, top=self.cells.raw[:9].decode())



class Driver:
    def __init__(self, wire, connection, trace):
        self.wire = wire
        self.connection = connection
        self.trace = trace
        self.acknowledge = True
        self.held_frames = []

    def exact(self, length):
        result = bytearray()
        while len(result) < length:
            data = self.connection.recv(length - len(result))
            if not data:
                raise EOFError('Unexpected EOF')
            result.extend(data)
        return bytes(result)

    def send(self, operation, value=0, text=b'', extra=b''):
        payload = self.wire.encode(operation, value, text, extra)
        self.connection.sendall(struct.pack('<I', len(payload)) + payload)

    def receive(self):
        prefix = self.exact(4)
        length = struct.unpack('<I', prefix)[0]
        if not 0 < length <= MAX_PAYLOAD:
            raise ValueError('Invalid frame length')
        payload = self.exact(length)
        self.trace.write(prefix + payload)
        self.trace.flush()
        event = self.wire.apply(payload)
        if event == Event.FRAME and self.acknowledge:
            self.send(Operation.ACK, self.wire.view.frame_id)
        return event

    def until(self, total, offset=None):
        while True:
            event = self.receive()
            view = self.wire.view
            if event == Event.FRAME and view.total == total and (offset is None or view.offset == offset):
                return self.wire.observation()

    def await_output(self):
        deadline = time.monotonic() + 10
        while True:
            assert time.monotonic() < deadline, 'Output did not complete while ACK was held'
            self.send(Operation.READ, self.wire.view.generation)
            while True:
                event = self.receive()
                if event == Event.FRAME:
                    assert self.wire.view.base_frame_id == 0, 'Replacement requires an independent snapshot'
                    if self.wire.view.total in (INITIAL_LINES + 1, INITIAL_LINES + ADDITIONAL_LINES + 1):
                        self.held_frames.append(self.wire.observation())
                if event in (Event.OUTPUT_COMPLETE, Event.OUTPUT_PENDING):
                    break
            if event == Event.OUTPUT_COMPLETE:
                return
            time.sleep(.001)

    def run(self, fixture, receipt, mode):
        self.send(Operation.HELLO)
        assert self.receive() == Event.ACCEPTED
        self.send(Operation.SUBSCRIBE, 103)
        self.wire.reflow = mode == 'reflow'
        self.send(Operation.OPEN_REFLOW if self.wire.reflow else Operation.OPEN, 1, str(fixture).encode(), str(receipt).encode())
        while self.receive() != Event.OPENED:
            pass
        initial = self.until(INITIAL_LINES + 1)
        assert initial['offset'] == initial['bottom']
        self.acknowledge = mode != 'held'
        self.send(Operation.VIEWPORT, initial['bottom'] - ROWS)
        historical = self.until(INITIAL_LINES + 1, initial['bottom'] - ROWS)
        if mode == 'reflow':
            self.wire.expected_columns = COLUMNS // 2
            self.send(Operation.RESIZE, COLUMNS // 2)
            narrow = self.until(INITIAL_LINES * 2 + 1)
            self.wire.expected_columns = COLUMNS
            self.send(Operation.RESIZE, COLUMNS)
            restored = self.until(INITIAL_LINES + 1)
            self.finish()
            return dict(mode=mode, initial=initial, historical=historical, narrow=narrow, restored=restored,
                        matches_expected=narrow['offset'] == historical['offset'] * 2 and restored['offset'] == historical['offset'],
                        cells_verified=True, child_exited=True)
        before_output = historical
        if mode != 'history':
            self.send(Operation.VIEWPORT, (1 << 32) - 1 if mode == 'clamp' else initial['bottom'])
            if mode != 'held':
                before_output = self.until(INITIAL_LINES + 1, initial['bottom'])
        self.send(Operation.INPUT, text=b'a')
        if mode == 'held':
            self.await_output()
            self.acknowledge = True
            self.send(Operation.ACK, self.wire.view.frame_id)
        total = INITIAL_LINES + ADDITIONAL_LINES + 1
        grown = self.wire.observation() if self.wire.view.total == total else self.until(total)
        self.finish()
        expected = historical['offset'] if mode == 'history' else grown['bottom']
        return dict(mode=mode, initial=initial, historical=historical, before_output=before_output,
                    grown=grown, held_frames=self.held_frames, follows_live=grown['offset'] == grown['bottom'],
                    matches_expected=grown['offset'] == expected, cells_verified=True, child_exited=True)

    def finish(self):
        self.send(Operation.INPUT, text=b'q')
        while self.receive() != Event.EXITED:
            pass
        self.send(Operation.CLOSE, 2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--wire', type=Path, required=True)
    parser.add_argument('--fixture', type=Path, required=True)
    parser.add_argument('socket')
    parser.add_argument('receipt', type=Path)
    parser.add_argument('mode', choices=('return', 'held', 'history', 'clamp', 'reflow'))
    args = parser.parse_args()
    if not __debug__:
        raise RuntimeError('Assertions must be enabled for this oracle')
    wire = Wire(args.wire.resolve(strict=True))
    with args.receipt.with_name('zig-wire.bin').open('xb') as trace, \
            socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(15)
        connection.connect(args.socket)
        result = Driver(wire, connection, trace).run(args.fixture.resolve(strict=True), args.receipt, args.mode)
        print(json.dumps(result))


if __name__ == '__main__':
    main()
