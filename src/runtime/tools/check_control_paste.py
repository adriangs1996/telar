#!/usr/bin/env python3
"""Mode5522 Surface completion and native replies, using memory MIME data only.

Only the random password field is normalized. Its decoded length/alphabet and
one-use behavior are verified independently; all remaining bytes must match.
This component oracle does not represent Qt, routing, or real PTY coverage.
"""
import argparse
import base64
import ctypes
import datetime
import hashlib
import json
import re
from pathlib import Path
from check_control_clipboard import DesktopProbe, OSC, ST, CONTENTS

PASSWORD = re.compile(rb':pw=([^:;\x1b\x07]+)')


def exercise(library, mode, primary, listing, split, flags, reference):
    probe = DesktopProbe(library)
    try:
        probe.configure(flags)
        probe.lib.query_probe_clipboard_clear.argtypes = [ctypes.c_void_p]
        probe.lib.query_probe_clipboard_clear(probe.ptr)
        for mime in listing:
            payload = next((data for name, data in CONTENTS if name == mime), b'fixture')
            assert probe.lib.query_probe_clipboard_put(probe.ptr, mime, payload, len(payload))
        assert probe.run(mode, min(split, len(mode))) == b''
        paste = probe.lib.query_probe_clipboard_paste
        paste.argtypes, paste.restype = [ctypes.c_void_p, ctypes.c_bool], ctypes.c_bool
        assert paste(probe.ptr, primary)
        event = probe.drain()
        result = {'event': PASSWORD.sub(b':pw=<random>', event).hex()}
        passwords = PASSWORD.findall(event)
        if passwords:
            assert len(set(passwords)) == 1
            decoded = base64.b64decode(passwords[0], validate=True)
            alphabet = (b'23456789abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ'
                        if reference else b'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_')
            assert len(decoded) == 22 and all(byte in alphabet for byte in decoded)
            location = b':loc=primary' if primary else b''
            request = OSC + b'5522;type=read:id=follow:name=QXBw:pw=' + passwords[0] + location + b';dGV4dC9wbGFpbg==' + ST
            result['first'] = probe.run(request, min(split, len(request))).hex()
            result['second'] = probe.run(request, min(split, len(request))).hex()
            if flags & 3 == 1 and not primary:
                assert b'status=OK' in bytes.fromhex(result['first'])
                assert b'status=EPERM' in bytes.fromhex(result['second'])
        else:
            assert event == b''
        result['contents'] = probe.contents()
        return result
    finally:
        probe.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--native', required=True, type=Path)
    parser.add_argument('--reference', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    listings = [[], [b'text/plain'], [name for name, _ in CONTENTS],
                [b'application/item-' + str(index).encode() for index in range(16)],
                [b'text/plain', b'application/' + '界'.encode()]]
    modes = [b'\x1b[?5522h', b'\x1b[?5522h\x1b[?5522l',
             b'\x1b[?5522h\x1bc', b'\x1b[?5522l\x1b[?5522h']
    failures, checks = [], 0
    for flags in [1 | 1 << 2, 2 | 2 << 2]:
        for mode in modes:
            for primary in [False, True]:
                for listing in listings:
                    # Includes every byte boundary of the longest follow-up.
                    for split in range(124):
                        observed = [exercise(path, mode, primary, listing, split, flags, reference)
                                    for path, reference in [(args.native, False), (args.reference, True)]]
                        checks += 1
                        if observed[0] != observed[1]:
                            failures.append({'mode': mode.hex(), 'primary': primary, 'listing': [m.hex() for m in listing],
                                             'split': split, 'flags': flags, 'native': observed[0], 'reference': observed[1]})
    report = {'recorded_at': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'scope': __doc__,
              'ghostty_revision': 'df1c99c8a5ec32c73963e5dc3fad3c9df7a3d137', 'checks': checks,
              'hashes': {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in [args.native, args.reference]},
              'failures': failures}
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'checks': checks, 'failures': len(failures)}))
    raise SystemExit(bool(failures))


if __name__ == '__main__':
    main()
