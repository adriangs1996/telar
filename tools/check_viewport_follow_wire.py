#!/usr/bin/env python3
"""Replay a viewport fixture capture and verify decoder/cell negative controls.

This is an offline oracle check, never a runtime or presentation benchmark.
Each damaged payload gets a fresh decoder with the valid preceding frames;
recovery after rejection is deliberately not assumed.
"""

import argparse
import ctypes
import hashlib
import json
from pathlib import Path
import struct

from viewport_follow_zig import Event, MAX_PAYLOAD, Wire


def read_capture(path):
    data = path.read_bytes()
    payloads = []
    offset = 0
    while offset < len(data):
        if offset + 4 > len(data):
            raise ValueError('Truncated length prefix')
        length = struct.unpack_from('<I', data, offset)[0]
        offset += 4
        if not 0 < length <= MAX_PAYLOAD or offset + length > len(data):
            raise ValueError('Truncated or invalid payload')
        payloads.append(data[offset:offset + length])
        offset += length
    return payloads


def check_capture(library, payloads, reflow=False):
    wire = Wire(library)
    wire.reflow = reflow
    kinds, bases = [], []
    for payload in payloads:
        kinds.append(wire.apply(payload))
        bases.append(wire.view.base_frame_id)
    assert kinds.count(Event.ACCEPTED) == kinds.count(Event.OPENED) == kinds.count(Event.EXITED) == 1
    assert kinds[0] == Event.ACCEPTED
    frames = [index for index, kind in enumerate(kinds) if kind == Event.FRAME]
    deltas = [index for index in frames if bases[index] != 0]
    assert frames and deltas, 'Both snapshot and delta coverage are required'
    wire.observation()
    rows = []

    def prefix(index):
        decoder = Wire(library)
        for payload in payloads[:index]:
            decoder.apply(payload)
        return decoder

    def reject(name, decoder, payload):
        result = decoder.library.viewport_apply(payload, len(payload), ctypes.byref(decoder.view),
                                                decoder.cells, len(decoder.cells))
        assert result < 0, name
        rows.append(dict(control=name, rejected=True))

    # The accepted handshake ends with its schema fingerprint.
    hello = bytearray(payloads[0])
    hello[-1] ^= 1
    reject('wrong accepted schema', Wire(library), bytes(hello))
    for index in frames:
        reject(f'truncated frame {index}', prefix(index), payloads[index][:-1])
        decoder = prefix(index)
        decoder.apply(payloads[index])
        reject(f'duplicate frame {index}', decoder, payloads[index])
        decoder = prefix(index)
        decoder.view.pane_id += 1
        reject(f'wrong pane {index}', decoder, payloads[index])
    for index in deltas:
        decoder = prefix(index)
        decoder.view.frame_id = 0
        reject(f'wrong base {index}', decoder, payloads[index])
    wire.cells[0] = b'X'
    try:
        wire.observation()
    except AssertionError:
        rows.append(dict(control='one decoded cell corruption', rejected=True))
    else:
        raise AssertionError('Cell oracle accepted corruption')
    return dict(frames=len(frames), deltas=len(deltas), controls=rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--wire', type=Path, required=True)
    parser.add_argument('--capture', type=Path, required=True)
    parser.add_argument('--reflow', action='store_true', help='Validate the long-row reflow fixture')
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    if not __debug__:
        raise RuntimeError('Assertions must be enabled for this oracle')
    library = args.wire.resolve(strict=True)
    report = check_capture(library, read_capture(args.capture), args.reflow)
    report.update(scope='Offline decoder/cell oracle only.', reflow=args.reflow,
                  bridge_sha256=hashlib.sha256(library.read_bytes()).hexdigest(),
                  capture_sha256=hashlib.sha256(args.capture.read_bytes()).hexdigest())
    with args.output.open('x') as output:
        output.write(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
