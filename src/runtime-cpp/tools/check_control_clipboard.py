#!/usr/bin/env python3
"""Actual application Surface versus native two-phase memory desktop.

Neither side calls a host clipboard. One asynchronous operation per feed is
settled before the next operation. Runtime routing/cancellation and real Qt
consumption are tested separately, not represented by this fixture.
"""
import argparse
import base64
import ctypes
import datetime
import hashlib
import json
from pathlib import Path
from control_query_oracle import Probe, ROOT

ST = b'\x1b\\'
OSC = b'\x1b]'
CONTENTS = [(b'text/plain', b'hello \xc3\xb1'), (b'text/html', b'<b>x</b>'), (b'application/octet-stream', b'\x00\xff\x01')]


class DesktopProbe(Probe):
    def configure(self, flags):
        for name, types, result in [
            ('config', [ctypes.c_void_p, ctypes.c_uint32], ctypes.c_bool),
            ('put', [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t], ctypes.c_bool),
            ('get', [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t], ctypes.c_size_t),
            ('count', [ctypes.c_void_p, ctypes.c_uint32], ctypes.c_uint64),
        ]:
            fn = getattr(self.lib, 'query_probe_clipboard_' + name)
            fn.argtypes, fn.restype = types, result
        assert self.lib.query_probe_clipboard_config(self.ptr, flags)
        for mime, data in CONTENTS:
            assert self.lib.query_probe_clipboard_put(self.ptr, mime, data, len(data))

    def contents(self):
        result = {}
        for mime, _ in CONTENTS:
            buffer = ctypes.create_string_buffer(4 * 1024 * 1024)
            length = self.lib.query_probe_clipboard_get(self.ptr, mime, buffer, len(buffer))
            if length != ctypes.c_size_t(-1).value:
                assert length <= len(buffer)
                result[mime.decode()] = buffer.raw[:length].hex()
        return result


def cases():
    for ending in [ST, b'\a', b'\x9c']:
        for selector in [b'', b'c', b'p', b's', b'cp', b'pc', b'cs', b'x']:
            yield 'OSC52-read-' + selector.decode() + '-' + ending.hex(), OSC + b'52;' + selector + b';?' + ending
        for payload in [b'', b'YQ==', b'YQ', b'YR==', b'YR', b'YWI=', b'YWI', b'YWJ=', b'YWJ', b'YWJj', b'YQ=', b'Y===', b'YQ===', b'YQ==YQ==', b'Y Q==', b'YQ==\n', b'!!', b'A', b'AB=C', b'AA==', b'/w==']:
            yield 'OSC52-write-' + payload.hex() + '-' + ending.hex(), OSC + b'52;c;' + payload + ending
        for requested in [b'', b'.', b'text/plain', b'TEXT UTF8_STRING STRING text/plain;charset=utf-8', b'text/html application/octet-stream .', b'text/missing', b'text/plain text/plain', b'. .', b'text/plain text/html . application/octet-stream text/missing']:
            for location in [b'', b':loc=primary']:
                yield 'Kitty-read-' + requested.hex() + location.decode() + '-' + ending.hex(), OSC + b'5522;type=read:id=read:name=QXBw:pw=cHc=' + location + b';' + base64.b64encode(requested) + ending
        for payload in [b'aGVsbG8=', b'aGVsbG8', b'YR==', b'YQ=', b'YQ==YQ==', b'AA==', b'/w==']:
            yield 'Kitty-write-' + payload.hex() + '-' + ending.hex(), (OSC + b'5522;type=write:id=write:name=QXBw:pw=cHc=' + ending + OSC + b'5522;type=wdata:mime=dGV4dC9wbGFpbg==;' + payload + ending + OSC + b'5522;type=wdata' + ending)
    for split in range(9):
        encoded = b'aGVsbG8='
        yield 'Kitty-quartet-boundary-' + str(split), (OSC + b'5522;type=write:id=x' + ST + OSC + b'5522;type=wdata:mime=dGV4dC9wbGFpbg==;' + encoded[:split] + ST + OSC + b'5522;type=wdata:mime=dGV4dC9wbGFpbg==;' + encoded[split:] + ST + OSC + b'5522;type=wdata' + ST)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--native', type=Path, default=ROOT / 'out-control-row/libcontrol-query-probe.dylib')
    parser.add_argument('--reference', type=Path, default=ROOT / 'dependencies/control-ghostty-oracle-desktop/lib/libghostty-control-oracle.dylib')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--all-splits', action='store_true')
    args = parser.parse_args()
    failures, checked = [], 0
    for policy, flags in [('deny', 0), ('ask-deny', 1 | 1 << 2), ('ask-once', 1 | 1 << 2 | 1 << 4), ('ask-session', 1 | 1 << 2 | 2 << 4), ('allow', 2 | 2 << 2)]:
        for name, data in cases():
            for split in range(len(data) + 1) if args.all_splits else [None]:
                observed = []
                for library in [args.native, args.reference]:
                    probe = DesktopProbe(library)
                    try:
                        probe.configure(flags)
                        reply = probe.run(data, split)
                        observed.append({'reply': reply.hex(), 'contents': probe.contents()})
                    finally:
                        probe.close()
                checked += 1
                if observed[0] != observed[1]:
                    failures.append({'case': name, 'policy': policy, 'split': split, 'input': data.hex(), 'native': observed[0], 'reference': observed[1]})
    report = {'recorded_at': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'scope': __doc__, 'ghostty_revision': 'df1c99c8a5ec32c73963e5dc3fad3c9df7a3d137', 'hashes': {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in [args.native, args.reference]}, 'checks': checked, 'failures': failures}
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'checks': checked, 'failures': len(failures)}))
    raise SystemExit(bool(failures))


if __name__ == '__main__':
    main()
