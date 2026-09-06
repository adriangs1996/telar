#!/usr/bin/env python3
"""Probe nonblocking Unix socket writes in disposable, timeout-bounded children."""
import json
import platform
import subprocess
import sys

CHILD = r'''
import fcntl, json, socket, sys
sender, receiver = socket.socketpair()
sender.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4096)
if sys.argv[1] == 'nonblocking-fd':
    sender.setblocking(False)
flags = socket.MSG_DONTWAIT | getattr(socket, 'MSG_NOSIGNAL', 0x80000 if sys.platform == 'darwin' else 0)
print(json.dumps(dict(flags=flags, fd_flags=fcntl.fcntl(sender, fcntl.F_GETFL))), flush=True)
for index in range(20000):
    try:
        if sys.argv[1] == 'sendmsg':
            size = sender.sendmsg([b'x' * 68], [], flags)
        else:
            size = sender.send(b'x' * 68, flags)
    except BlockingIOError:
        print(json.dumps(dict(would_block=True, completed=index)), flush=True)
        break
    if index % 10 == 0:
        print(json.dumps(dict(completed=index + 1, last_bytes=size)), flush=True)
else:
    raise RuntimeError('fixture did not reach backpressure')
'''


def probe(mode):
    try:
        result = subprocess.run([sys.executable, '-u', '-c', CHILD, mode],
                                capture_output=True, timeout=2)
        return dict(mode=mode, timed_out=False, returncode=result.returncode,
                    stdout=result.stdout.decode(), stderr=result.stderr.decode())
    except subprocess.TimeoutExpired as error:
        # subprocess.run kills and joins this child before raising.
        return dict(mode=mode, timed_out=True, stdout=(error.stdout or b'').decode(),
                    stderr=(error.stderr or b'').decode())


if __name__ == '__main__':
    print(json.dumps(dict(platform=platform.platform(),
                          results=[probe(mode) for mode in ['send', 'sendmsg', 'nonblocking-fd']]), indent=2))
