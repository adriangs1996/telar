"""Executable and connected peer identities for native macOS stack measurements."""
import ctypes
import hashlib
import os
from pathlib import Path
import socket
import time


LOCAL_PEERPID = 0x002
SOL_LOCAL = 0
PROC_PIDPATHINFO_MAXSIZE = 4096


def executable_identity(path):
    path = Path(path).resolve(strict=True)
    return dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest())


def process_identity(pid):
    library = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    library.proc_pidpath.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(PROC_PIDPATHINFO_MAXSIZE)
    if library.proc_pidpath(pid, buffer, len(buffer)) <= 0:
        raise OSError(ctypes.get_errno(), f'Cannot identify process {pid}')
    return dict(pid=pid, **executable_identity(buffer.value.decode()))


def runtime_identity(socket_path, expected, timeout=5):
    deadline = time.monotonic() + timeout
    while True:
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.connect(str(socket_path))
                pid = connection.getsockopt(SOL_LOCAL, LOCAL_PEERPID)
                identity = process_identity(pid)
            break
        except (FileNotFoundError, ConnectionRefusedError):
            if time.monotonic() >= deadline:
                raise TimeoutError(f'Runtime socket did not become ready: {socket_path}')
            time.sleep(.01)
    if identity['path'] != str(Path(expected).resolve(strict=True)):
        raise ValueError(f'Runtime socket belongs to an unexpected executable: {identity}')
    return dict(socket=str(socket_path), **identity)


def staged_runtime(gui, expected):
    directory = Path(gui).resolve(strict=True).parent
    for candidate in (directory / 'telar', directory / '../Resources/bin/telar'):
        if candidate.is_file() and os.access(candidate, os.X_OK):
            identity = executable_identity(candidate)
            if identity['sha256'] != executable_identity(expected)['sha256']:
                raise ValueError(f'GUI runtime helper differs from selected runtime: {candidate}')
            return identity
    raise ValueError('Stage the selected runtime as telar beside the C++ GUI or in Contents/Resources/bin')
