#!/usr/bin/env python3
"""Clipboard CLI wire tests with private sockets; never access a host clipboard."""
import argparse
import os
from pathlib import Path
import pty
import socket
import struct
import subprocess
import tempfile
import threading

from pane_agent_test import environment, integer, receive, send, text


def check(binary, root):
    env = environment(root)
    calls = 0

    def run(payload=b'', mime='text/plain;charset=utf-8', mode='ok'):
        nonlocal calls
        path = root / f'clipboard-{calls}.sock'
        calls += 1
        errors = []
        with socket.socket(socket.AF_UNIX) as listener:
            listener.bind(str(path))
            listener.listen()

            def serve():
                try:
                    connection, _ = listener.accept()
                    with connection:
                        connection.settimeout(5)
                        hello = receive(connection)
                        send(connection, b'TELARIPC\x02' + hello[9:])
                        offset = 0
                        transfer = None
                        while (frame := receive(connection)) is not None:
                            assert frame[0] == 0x4b and len(frame) == 25
                            request, capture, requested_offset = struct.unpack('<QQQ', frame[1:])
                            assert requested_offset == offset
                            if transfer is None:
                                assert capture == 0
                                transfer = request
                            else:
                                assert capture == transfer
                            if mode == 'refused':
                                send(connection, b'\x84' + integer(request) + integer(2, 'H') + b'No graphical session')
                                return
                            if mode == 'disconnect':
                                return
                            part = payload[offset:offset + 65536]
                            reply = (b'\xba' + integer(request) + integer(transfer) + integer(offset + (mode == 'offset'))
                                     + integer(len(payload) if mode != 'oversize' else 33554433)
                                     + text(mime) + text(part, 'I'))
                            send(connection, reply)
                            if mode in ('offset', 'oversize'):
                                return
                            offset += len(part)
                            if offset == len(payload):
                                return
                except Exception as error:
                    errors.append(error)

            worker = threading.Thread(target=serve)
            worker.start()
            command = [str(binary), 'clipboard', 'get', '--socket', str(path)]
            result = subprocess.run(command, env=env, capture_output=True, timeout=8, stdin=subprocess.DEVNULL)
            worker.join(8)
            assert not worker.is_alive() and not errors, errors
            return result

    for payload, mime in [(b'', 'text/plain'), ('hello\n\x00á'.encode(), 'text/plain;charset=utf-8'),
                          (bytes(range(256)) * 1025, 'image/png'), (b'II*\0' + b'x' * 80000, 'image/tiff')]:
        result = run(payload, mime)
        assert result.returncode == 0 and result.stdout == payload and result.stderr == b'', result
    for mode in ('refused', 'disconnect', 'offset', 'oversize'):
        result = run(b'image', 'image/png', mode)
        assert result.returncode != 0 and result.stdout == b'' and result.stderr, (mode, result)
    assert b'No graphical session' in run(mode='refused').stderr
    for words in [[], ['put'], ['get', '--json'], ['get', '--socket']]:
        result = subprocess.run([str(binary), 'clipboard', *words], env=env, capture_output=True, timeout=5)
        assert result.returncode != 0 and result.stdout == b''
    master, slave = pty.openpty()
    try:
        for prefix in ([], ['--machine', 'missing']):
            result = subprocess.run([str(binary), *prefix, 'clipboard', 'get'], env=env,
                                    stdin=subprocess.DEVNULL, stdout=slave, stderr=subprocess.PIPE, timeout=5)
            assert result.returncode != 0 and b'redirect stdout' in result.stderr
    finally:
        os.close(slave)
        os.close(master)
    print('Clipboard CLI: byte-exact text/images, multi-chunk reads, empty text, failures, bounds and terminal protection passed')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--telar', type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='telar-clipboard-', dir='/tmp') as directory:
        check(args.telar.resolve(), Path(directory))
