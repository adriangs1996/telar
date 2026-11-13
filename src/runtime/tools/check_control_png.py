#!/usr/bin/env python3
"""PNG query completion against the frozen application's real Wuffs decoder."""
import argparse
import base64
import binascii
import datetime
import hashlib
import json
from pathlib import Path
import struct
import sys
import zlib
from control_query_oracle import Probe, GHOSTTY, NATIVE


def chunk(kind, data):
    return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', binascii.crc32(kind + data))


def image(depth=8, color=6, interlace=0, split=None, trailing=b'', before=b''):
    pixels = {0: bytes([0xff]) if depth <= 8 else b'\xff\xff',
             2: b'\xff\0\0' if depth == 8 else b'\xff\xff\0\0\0\0',
             4: b'\x80\xff' if depth == 8 else b'\x80\0\xff\xff',
             6: b'\xff\0\0\xff' if depth == 8 else b'\xff\xff\0\0\0\0\xff\xff'}
    pixel = bytes([1 << (8 - depth)]) if color == 3 else pixels[color]
    header = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!IIBBBBB', 1, 1, depth, color, 0, 0, interlace))
    if color == 3:
        header += chunk(b'PLTE', b'\xff\0\0\0\xff\0') + chunk(b'tRNS', b'\xff\0')
    compressed = zlib.compress(b'\0' + pixel)
    data = chunk(b'IDAT', compressed) if split is None else chunk(b'IDAT', compressed[:split]) + chunk(b'IDAT', compressed[split:])
    return header + before + data + chunk(b'IEND', b'') + trailing


def cases():
    valid = image()
    yield 'valid-rgba', valid
    for length in range(len(valid)):
        yield 'rgba-prefix-' + str(length), valid[:length]
    for position in range(len(valid)):
        for bit in [0, 7]:
            mutated = bytearray(valid)
            mutated[position] ^= 1 << bit
            yield f'rgba-mutation-{position}-{bit}', bytes(mutated)
    for color, depths in [(0, [1, 2, 4, 8, 16]), (2, [8, 16]), (3, [1, 2, 4, 8]), (4, [8, 16]), (6, [8, 16])]:
        for depth in depths:
            for interlace in [0, 1]:
                data = image(depth, color, interlace)
                yield f'format-{color}-{depth}-{interlace}', data
                yield f'format-no-iend-{color}-{depth}-{interlace}', data[:-12]
    for offset in range(14):
        yield 'idat-split-' + str(offset), image(split=offset)
    for tail in [b'garbage', b'\0' * 16, chunk(b'IEND', b''), chunk(b'IDAT', zlib.compress(b'other stream'))]:
        yield 'trailing-' + tail.hex(), image(trailing=tail)
    for kind in [b'tEXt', b'iTXt', b'unknown', b'ABCD']:
        # PNG types are four bytes; text payload itself is intentionally varied.
        yield 'before-idat-' + kind.hex(), image(before=chunk(kind[:4], b'note\0value'))
    yield 'text-4096', image(before=chunk(b'tEXt', b'note\0' + b'x' * 4096))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--native', type=Path, default=NATIVE)
    parser.add_argument('--reference', type=Path, default=GHOSTTY)
    parser.add_argument('--all-splits', action='store_true')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    checked = 0
    failed = 0
    failures = []
    for name, data in cases():
        for compression in [False, True]:
            encoded = zlib.compress(data) if compression else data
            wire = b'\x1b_Ga=q,i=9,f=100' + (b',o=z' if compression else b'') + b';' + base64.b64encode(encoded) + b'\x1b\\'
            splits = range(len(wire) + 1) if args.all_splits else [None]
            for split in splits:
                replies = []
                for library in [args.native, args.reference]:
                    probe = Probe(library.resolve())
                    try:
                        replies.append(probe.run(wire, split))
                    finally:
                        probe.close()
                checked += 1
                if replies[0] != replies[1]:
                    failed += 1
                    if len(failures) < 100:
                        failures.append({'case': name, 'compression': compression, 'split': split,
                                         'input_hex': wire.hex(), 'native': replies[0].hex(), 'reference': replies[1].hex()})
    report = {'recorded_at': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'checked': checked,
              'failed': failed, 'failures': failures, 'command': sys.argv,
              'libraries': {str(path.resolve()): hashlib.sha256(path.read_bytes()).hexdigest() for path in [args.native, args.reference]},
              'scope': 'PTY response bytes from native controller versus immutable application StreamHandler and its Wuffs PNG default. Synthetic data only, no host clipboard or resource files.'}
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'checked': checked, 'failed': failed}))
    return bool(failed)


if __name__ == '__main__':
    sys.exit(main())
