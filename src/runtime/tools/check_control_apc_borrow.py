#!/usr/bin/env python3
"""Compare long APC queries at every boundary, including control bytes."""
import argparse
import base64
import ctypes
import datetime
import hashlib
import json
from pathlib import Path
import sys
from control_query_oracle import Probe, GHOSTTY, ForeignResponse


def cases():
    raw = bytes(range(256)) * 4
    payload = base64.b64encode(raw)
    prefix = b'\x1b_Ga=q,i=9,s=16,v=16;'
    for ending in [b'\x1b\\', b'\x1bX', b'\x18', b'\x1a', b'\x9c']:
        yield 'ending-' + ending.hex(), prefix + payload + ending + b'\x1b[5n'
    for control in [0, 5, 7, 24, 26, 27, 31, 32, 127, 128, 144, 152, 155, 156, 158, 159, 160, 255]:
        for position in [0, len(payload) // 2, len(payload)]:
            body = payload[:position] + bytes([control]) + payload[position:]
            yield f'payload-{control}-{position}', prefix + body + b'\x1b\\\x1b[5n'
    yield 'embedded-separator', prefix + payload[:512] + b';' + payload[512:] + b'\x1b\\\x1b[5n'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--native', type=Path, required=True)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    libraries = [args.native.resolve(), args.baseline.resolve(), GHOSTTY]
    probes = [Probe(library) for library in libraries]
    buffer = ctypes.create_string_buffer(4096)
    checked = 0
    baseline_differences = 0
    application_differences = 0
    case_differences = {}
    failures = []
    failed = 0
    for name, wire in cases():
        for split in [None, *range(len(wire) + 1)]:
            replies = []
            for probe in probes:
                if not probe.ptr:
                    probe.ptr = probe.lib.query_probe_new(80, 24, 9, 18)
                    if not probe.ptr:
                        raise RuntimeError('Probe construction failed')
                try:
                    for part in [wire] if split is None else [wire[:split], wire[split:]]:
                        probe.feed(part)
                    reply = bytearray()
                    while size := probe.lib.query_probe_drain(probe.ptr, buffer, len(buffer)):
                        reply.extend(buffer.raw[:size])
                    if probe.foreign_calls and probe.foreign_calls(probe.ptr):
                        raise ForeignResponse(bytes(reply), probe.foreign_calls(probe.ptr))
                    replies.append(bytes(reply))
                finally:
                    probe.close()
            checked += 1
            baseline_differences += replies[0] != replies[1]
            application_differences += replies[0] != replies[2]
            if len(set(replies)) != 1:
                failed += 1
                case_differences[name] = case_differences.get(name, 0) + 1
                if len(failures) < 50:
                    failures.append({'case': name, 'split': split, 'responses': [r.hex() for r in replies]})
    report = {'recorded_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'checked': checked, 'triple_differences': failed, 'differences': failures,
              'candidate_vs_baseline_differences': baseline_differences,
              'candidate_vs_application_differences': application_differences,
              'case_differences': case_differences,
              'libraries': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in libraries},
              'harness_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              'command': sys.argv, 'scope': 'Long native graphics query response bytes; all two-fragment boundaries. Foreign response callbacks must remain zero.'}
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'checked': checked, 'application_differences': application_differences, 'baseline_differences': baseline_differences}))
    return bool(application_differences)


if __name__ == '__main__':
    sys.exit(main())
