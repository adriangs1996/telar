#!/usr/bin/env python3
"""A synthetic Kitty host verifies a complete 4K inline/zlib roundtrip."""
import base64
import hashlib
import os
from pathlib import Path
import random
import select
import shlex
import subprocess
import time
import zlib

import load_latency


class Host:
    def __init__(self, master, expected):
        self.master = master
        self.expected = expected
        self.buffer = bytearray()
        self.payload = bytearray()
        self.metadata = None
        self.result = None
        self.bytes_received = 0

    def feed(self, data):
        self.bytes_received += len(data)
        self.buffer.extend(data)
        while True:
            start = self.buffer.find(b'\x1b_G')
            if start < 0:
                self.buffer = self.buffer[-2:]
                return
            end = self.buffer.find(b'\x1b\\', start + 3)
            if end < 0:
                self.buffer = self.buffer[start:]
                if len(self.buffer) > 1024 * 1024:
                    raise RuntimeError('unbounded host APC')
                return
            body = bytes(self.buffer[start + 3:end])
            del self.buffer[:end + 2]
            control, _, encoded = body.partition(b';')
            attributes = dict(field.split(b'=', 1) for field in control.split(b',') if b'=' in field)
            if attributes.get(b'a') == b'q':
                image_id = attributes.get(b'i', b'0')
                os.write(self.master, b'\x1b_Gi=' + image_id + b';OK\x1b\\\x1b[6;20;10t')
                continue
            if attributes.get(b'a') in (b't', b'T'):
                self.metadata = attributes
                self.payload.clear()
            elif b'm' not in attributes or self.metadata is None:
                continue
            self.payload.extend(base64.b64decode(encoded, validate=True))
            if len(self.payload) > 64 * 1024 * 1024:
                raise RuntimeError('image exceeded host test quota')
            if attributes.get(b'm', b'0') != b'0':
                continue
            metadata, self.metadata = self.metadata, None
            if metadata.get(b's') != b'3840' or metadata.get(b'v') != b'2160':
                continue
            decoded = zlib.decompress(self.payload) if metadata.get(b'o') == b'z' else self.payload
            digest = hashlib.sha256(decoded).hexdigest()
            if len(decoded) != 3840 * 2160 * 4 or digest != self.expected:
                raise RuntimeError('4K roundtrip changed the pixel bytes')
            self.result = dict(pixel_bytes=len(decoded), sha256=digest,
                               compressed=metadata.get(b'o') == b'z', wire_payload_bytes=len(self.payload))

    def poll(self, duration):
        ready, _, _ = select.select([self.master], [], [], duration)
        if ready:
            self.feed(os.read(self.master, 65536))


def fixture(directory):
    pixels = bytearray(b'0' * (3840 * 2160 * 4))
    pixels[3::16] = random.Random(9).randbytes(len(pixels[3::16]))
    digest = hashlib.sha256(pixels).hexdigest()
    path = Path(directory) / 'frame.kgp'
    encoded_pixels = zlib.compress(pixels, level=1)
    with path.open('wb') as stream:
        for offset in range(0, len(encoded_pixels), 3072):
            chunk = encoded_pixels[offset:offset + 3072]
            more = int(offset + len(chunk) < len(encoded_pixels))
            fields = (b'a=T,f=32,o=z,s=3840,v=2160,i=77,q=2,' if offset == 0 else b'') + f'm={more}'.encode()
            stream.write(b'\x1b_G' + fields + b';' + base64.b64encode(chunk) + b'\x1b\\')
    return path, digest


def measure(binary, directory, env):
    path, digest = fixture(directory)
    env = {**env, 'TERM_PROGRAM': 'telar-perf-host'}
    master, slave = load_latency.pty.openpty()
    load_latency.set_winsize(slave, 70, 240)
    proc = subprocess.Popen([binary, '--no-config', '--sidebar-renderer', 'cells'],
                            stdin=slave, stdout=slave, stderr=slave, env=env,
                            preexec_fn=load_latency.become_session_leader, close_fds=True)
    os.close(slave)
    host = Host(master, digest)
    try:
        warmup = time.perf_counter() + 3
        while time.perf_counter() < warmup:
            host.poll(.05)
        started = time.perf_counter()
        os.write(master, f'cat {shlex.quote(str(path))}\n'.encode())
        while host.result is None and time.perf_counter() - started < 45:
            host.poll(.05)
        if host.result is None:
            raise RuntimeError('4K host transmission did not complete within 45 seconds')
        return {**host.result, 'elapsed_ms': (time.perf_counter() - started) * 1000,
                'host_bytes': host.bytes_received}
    finally:
        load_latency.terminate(proc)
        os.close(master)
