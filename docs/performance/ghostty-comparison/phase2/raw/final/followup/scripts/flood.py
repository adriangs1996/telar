#!/usr/bin/env python3
"""Output flood throughput through a terminal multiplexer.

Runs the multiplexer in a pty whose shell is /bin/sh, types a command that
prints N lines followed by a marker, and measures the time from typing the
command until the marker is visible on the multiplexer's output.
"""

import argparse
import fcntl
import os
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import termios
import time

MARKER = b"ZQENDMARKER%dQZ"
ESCAPES = re.compile(
    rb"\x1b\[[0-?]*[ -/]*[@-~]"
    rb"|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"
    rb"|\x1bP[^\x1b]*\x1b\\"
    rb"|\x1b[@-Z\\-_]"
)


def set_winsize(fd, rows, cols):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def drain(master, seconds):
    end = time.perf_counter() + seconds
    out = b""
    while True:
        remaining = end - time.perf_counter()
        if remaining <= 0:
            return out
        r, _, _ = select.select([master], [], [], remaining)
        if not r:
            continue
        try:
            out += os.read(master, 1 << 16)
        except OSError:
            return out


def terminate(proc):
    """Ends the multiplexer's process group; a client that ignores SIGTERM
    or re-parents its children still must not hang the measurement."""
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(proc.pid, sig)
        except (ProcessLookupError, PermissionError):
            proc.kill()
        try:
            proc.wait(timeout=3)
            return
        except subprocess.TimeoutExpired:
            continue


def become_session_leader():
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)


def run(cmd, env, lines, rows, cols, warmup, repeats, dump):
    master, slave = pty.openpty()
    set_winsize(slave, rows, cols)
    proc = subprocess.Popen(
        cmd, stdin=slave, stdout=slave, stderr=slave, env=env,
        preexec_fn=become_session_leader, close_fds=True,
    )
    os.close(slave)
    banner = drain(master, warmup)
    if proc.poll() is not None:
        sys.stderr.write(banner.decode("utf-8", "replace"))
        raise SystemExit(f"{cmd[0]} exited early with {proc.returncode}")

    results = []
    for repeat in range(repeats):
        # A repeat-specific marker: the previous one is still on screen and
        # the diff repaints it when the rows scroll.
        marker = MARKER % repeat
        command = f"seq 1 {lines}; echo ZQEND\"\"MARKER{repeat}QZ\n".encode()
        buf = b""
        total = 0
        t0 = time.perf_counter()
        os.write(master, command)
        deadline = t0 + 60
        while True:
            remaining = deadline - time.perf_counter()
            if remaining <= 0:
                results.append(None)
                break
            r, _, _ = select.select([master], [], [], remaining)
            if not r:
                continue
            data = os.read(master, 1 << 16)
            if dump is not None:
                dump.write(data)
            total += len(data)
            buf = (buf + data)[-8192:]
            if marker in ESCAPES.sub(b"", buf):
                results.append((time.perf_counter() - t0, total))
                break
        drain(master, 1.0)

    terminate(proc)
    os.close(master)
    return results


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("name")
    parser.add_argument("cmd", nargs="+")
    parser.add_argument("--lines", type=int, default=300000)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--rows", type=int, default=40)
    parser.add_argument("--cols", type=int, default=160)
    parser.add_argument("--warmup", type=float, default=3.0)
    parser.add_argument("--env", action="append", default=[])
    parser.add_argument("--dump", help="write every host byte to this file")
    args = parser.parse_args()

    env = dict(os.environ)
    env["SHELL"] = "/bin/sh"
    env["TERM"] = "xterm-256color"
    env["PS1"] = "$ "
    for key in list(env):
        if key.startswith("TELAR_") or key.startswith("TMUX") or key.startswith("HERDR"):
            del env[key]
    for pair in args.env:
        key, _, value = pair.partition("=")
        env[key] = value

    dump = open(args.dump, "wb") if args.dump else None
    results = run(args.cmd, env, args.lines, args.rows, args.cols, args.warmup, args.repeats, dump)
    if dump is not None:
        dump.close()
    for result in results:
        if result is None:
            print(f"{args.name:8s} timeout")
        else:
            seconds, out_bytes = result
            print(f"{args.name:8s} {seconds*1000:9.1f} ms  host_bytes={out_bytes}")


if __name__ == "__main__":
    main()
