#!/usr/bin/env python3
"""Compare full native Terminal state and replies at every SGR byte boundary."""
import argparse
import ctypes
import hashlib
import json
from pathlib import Path
import random
from control_query_oracle import Probe


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    probes = [Probe(path) for path in [args.baseline, args.candidate]]
    for probe in probes:
        probe.lib.query_probe_screen_digest.argtypes = [ctypes.c_void_p]
        probe.lib.query_probe_screen_digest.restype = ctypes.c_uint64
        probe.policy(2)
    bodies = [b'm', b'0m', b'1;32m', b'38;2;1;2;3m', b'4:3m', b'38:2::4:5:6m',
              b';m', b';;m', b'1;2;m', b'65535m', b'65536m', b'999999999999999999999999m',
              b'>4m', b'?1m', b'1 m', b'1!m', b'1\x7f;32m', b'1\x18m', b'1\x1am']
    for size in [23, 24, 25, 26, 254, 255, 256]:
        bodies += [b'9' * size + b'm', b';' * size + b'm', b'1;' * size + b'm', b'1;' * size + b'1m']
    generator = random.Random(0x713a34)
    for _ in range(48):
        bodies.append(b';'.join(str(generator.randrange(100000)).encode() for _ in range(generator.randrange(1, 12))) + b'm')
    contexts = [b'A', b'\r\n', b'\xf0\x9f', b'\xf0\x9f\r\n', b'\x1b[?6h\x1b[3;20r',
                b'\x1b[?1049h', b'\x1b[31mA\x1b[!p']
    suffix = b'Z\x1bP$qm\x1b\\\x1b[6n\x1b[?6n\x1b[1;1;1;1;24;80*y'
    checked = 0
    for index, body in enumerate(bodies):
        prefix = contexts[index % len(contexts)]
        data = prefix + b'\x1b[' + body + suffix
        for split in [None, *range(len(data) + 1), 'bytes']:
            actual = []
            for probe in probes:
                probe.run(b'\x1bc')
                if split == 'bytes':
                    for byte in data:
                        probe.feed(bytes([byte]))
                    reply = probe.drain()
                    if probe.foreign_calls(probe.ptr):
                        raise AssertionError('Foreign response handler reached')
                else:
                    reply = probe.run(data, split)
                digest = probe.lib.query_probe_screen_digest(probe.ptr)
                if not digest:
                    raise AssertionError('Screen digest failed')
                actual.append((reply, digest))
            if actual[0] != actual[1]:
                raise AssertionError(f'SGR state/reply mismatch: body={body.hex()}, split={split}')
            checked += 1
    for probe in probes:
        probe.close()
    report = {'bodies': len(bodies), 'executions': checked, 'differences': 0,
              'scope': 'Full native Terminal baseline/candidate,80x24 packed active cells and exact DECRQSS/cursor/checksum replies; no scrollback digest. Every split and byte-at-a-time.',
              'hashes': {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in
                         [args.baseline, args.candidate, Path(__file__)]}}
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))


if __name__ == '__main__':
    main()
