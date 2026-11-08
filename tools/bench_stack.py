"""Executable and peer identities, isolated runtimes and quantiles for stack measurements."""
import ctypes
import hashlib
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
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


def percentile(values, p):
    values = sorted(values)
    k = (len(values) - 1) * p
    lo = int(k)
    hi = min(lo + 1, len(values) - 1)
    return values[lo] + (values[hi] - values[lo]) * (k - lo)


def runtime_pids(socket_path):
    rows = subprocess.check_output(['ps', '-axo', 'pid,command'], text=True)
    return [int(row.split(None, 1)[0]) for row in rows.splitlines()[1:]
            if ' server --daemonized ' in row and f'--socket {socket_path} ' in row]


def process_table():
    rows = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,lstart=,command='], text=True)
    table = {}
    for row in rows.splitlines():
        fields = row.split(None, 7)
        if len(fields) == 8:
            table[int(fields[0])] = (int(fields[1]), ' '.join(fields[2:7]), fields[7])
    return table


def descendants(roots):
    table = process_table()
    owned = set(roots)
    while True:
        children = {pid for pid, (parent, _, _) in table.items() if parent in owned}
        if children <= owned:
            return {pid: table[pid] for pid in owned if pid in table}
        owned |= children


def owned_sessions(owned):
    sessions = set()
    for pid in owned:
        try:
            sessions.add(os.getsid(pid))
        except ProcessLookupError:
            pass
    if sessions & {os.getsid(0), os.getsid(os.getppid())}:
        raise RuntimeError('isolated runtime shares the runner session')
    return sessions


def session_members(sessions):
    members = []
    for pid in process_table():
        try:
            if os.getsid(pid) in sessions:
                members.append(pid)
        except ProcessLookupError:
            pass
    return members


def cleanup_sessions(sessions):
    if sessions & {os.getsid(0), os.getsid(os.getppid())}:
        raise RuntimeError('refusing to clean the runner session')
    if not sessions:
        return
    for pid in session_members(sessions):
        if pid in (os.getpid(), os.getppid()):
            raise RuntimeError('refusing to signal the runner or its parent')
        try:
            if os.getsid(pid) in sessions:
                os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    deadline = time.perf_counter() + 2
    while session_members(sessions) and time.perf_counter() < deadline:
        time.sleep(.05)
    remaining = session_members(sessions)
    if remaining:
        raise RuntimeError(f'isolated processes survived cleanup: {remaining}')


def stop_runtime(binary, env):
    pids = runtime_pids(env['TELAR_SOCKET_PATH'])
    sessions = owned_sessions(descendants(pids))
    started = time.perf_counter()
    try:
        command = subprocess.run([binary, 'server', 'stop'], env=env,
                                 capture_output=True, timeout=5)
        reply = command.stdout.decode(errors='replace')
        code = command.returncode
    except subprocess.TimeoutExpired:
        reply, code = 'stop command timed out', -1
    deadline = started + 5
    while time.perf_counter() < deadline and runtime_pids(env['TELAR_SOCKET_PATH']):
        time.sleep(.02)
    remaining = runtime_pids(env['TELAR_SOCKET_PATH'])
    result = dict(elapsed_ms=(time.perf_counter() - started) * 1000,
                  exited=not remaining, returncode=code, reply=reply, pids=pids)
    # Session membership survives exec, reparenting and foreground-job changes.
    survivors = session_members(sessions)
    result['children_exited'] = not [pid for pid in survivors if pid not in pids]
    result['socket_removed'] = not Path(env['TELAR_SOCKET_PATH']).exists()
    cleanup_sessions(sessions)
    result['cleanup_complete'] = True
    return result


def isolated_environment(directory):
    directory.mkdir(mode=0o700, parents=True)
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('TELAR_', 'TMUX', 'HERDR'))}
    for name in ('data', 'config', 'cache'):
        (directory / name).mkdir(mode=0o700)
    env.update(TERM='xterm-256color', SHELL='/bin/sh', PS1='$ ',
               XDG_DATA_HOME=str(directory / 'data'),
               XDG_CONFIG_HOME=str(directory / 'config'),
               XDG_CACHE_HOME=str(directory / 'cache'),
               TELAR_SOCKET_PATH=str(short_socket_path(directory)))
    return env


def short_socket_path(directory):
    """A Unix socket path must fit in about 100 bytes; a deep output
    directory would not, so the socket lives in a short private directory
    that `directory` links to."""
    path = directory / 'runtime.sock'
    if len(str(path)) < 100:
        return path
    socket_directory = Path(tempfile.mkdtemp(prefix='tlr-'))
    (directory / 'runtime-socket-dir').symlink_to(socket_directory)
    return socket_directory / 'runtime.sock'
