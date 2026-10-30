#!/usr/bin/env python3
"""Compare reset and saved subscriptions with the actual pinned application."""
import argparse
import ctypes
import hashlib
import json
from pathlib import Path
from control_query_oracle import Probe, GHOSTTY

CSI = b'\x1b['
RIS = b'\x1bc'
SOFT = CSI + b'!p'


def cases():
    for mode in [b'2031', b'2033', b'1004', b'2048', b'5522', b'2031;2033;1004;2048;5522']:
        prefix = CSI + b'?' + mode
        queries = b''.join(CSI + b'?' + part + b'$p' for part in mode.split(b';'))
        flows = {
            'restore-enabled': prefix + b'h' + prefix + b's' + prefix + b'l' + prefix + b'r' + queries,
            'restore-disabled': prefix + b'l' + prefix + b's' + prefix + b'h' + prefix + b'r' + queries,
            'restore-repeated': prefix + b'h' + prefix + b's' + prefix + b'r' + prefix + b'r' + queries,
            'RIS': prefix + b'h' + prefix + b's' + RIS + prefix + b'r' + queries,
            'DECSTR': prefix + b'h' + prefix + b's' + SOFT + prefix + b'l' + prefix + b'r' + queries,
            'alternate': prefix + b'h' + prefix + b's' + CSI + b'?1049h' + queries + CSI + b'?1049l' + prefix + b'l' + prefix + b'r' + queries,
        }
        for name, data in flows.items():
            yield mode.decode() + '-' + name, data
    for flags in range(32):
        for name, reset in [('RIS', RIS), ('DECSTR', SOFT), ('alternate', CSI + b'?1049h' + CSI + b'?1049l')]:
            yield f'checksum-{flags}-{name}', b'A' + CSI + str(flags).encode() + b'#y' + CSI + b'1;1;1;1;1;1*y' + reset + CSI + b'2;1;1;1;1;1*y'
    yield 'keyboard-per-screen', b'A' + CSI + b'>1u' + CSI + b'?u' + CSI + b'?1049h' + CSI + b'?u' + CSI + b'>2u' + CSI + b'?u' + CSI + b'?1049l' + CSI + b'?u'
    yield 'keyboard-RIS', CSI + b'>7u' + RIS + CSI + b'?u' + CSI + b'?1049h' + CSI + b'?u'
    yield 'keyboard-DECSTR', CSI + b'>7u' + SOFT + CSI + b'?u'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--native', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    checked = 0
    failures = []
    rows = []
    for name, data in cases():
        reference = Probe(GHOSTTY)
        try:
            reference.policy(2)
            expected = reference.run(data)
        finally:
            reference.close()
        rows.append({'case': name, 'input_hex': data.hex(), 'reference_hex': expected.hex()})
        for split in range(len(data) + 1):
            native = Probe(args.native)
            try:
                native.policy(2)
                facts = native.lib.query_probe_facts
                facts.argtypes = [ctypes.c_void_p, ctypes.c_bool, ctypes.c_bool, ctypes.c_bool]
                facts.restype = ctypes.c_bool
                if not facts(native.ptr, False, True, True) or native.drain():
                    raise AssertionError('Could not establish equivalent client facts')
                actual = native.run(data, split)
            finally:
                native.close()
            checked += 1
            if actual != expected:
                failures.append({'case': name, 'split': split, 'expected_hex': expected.hex(), 'actual_hex': actual.hex()})
                break
    report = {'checked': checked, 'cases': rows, 'failures': failures,
              'client_facts': 'Native explicitly dark/visible/focused to match the application fixture; Telar no-client defaults remain separately asserted.',
              'policy': 'Checksum explicitly allowed in both fixtures; no desktop provider or host clipboard is accessed.',
              'hashes': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in [args.native, GHOSTTY, Path(__file__)]}}
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'checked': checked, 'cases': len(rows), 'failed': len(failures), 'failures': failures}))
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
