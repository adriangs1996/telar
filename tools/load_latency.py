#!/usr/bin/env python3
"""Keystroke-to-echo latency while other panes flood the multiplexer.

Opens `--floods` extra panes, each running an endless `seq` loop, then measures
single-byte echo latency in one idle pane exactly like echo_latency.py. The
question it answers is whether the per-operation scheduling cost of the
runtime shows up when several ptys are busy at once.

telar panes are opened by typing the default prefix bindings into the client;
tmux panes are opened from outside with `split-window -d`, which keeps focus
on the measured pane.
"""

import argparse
import fcntl
import os
import pty
import re
import select
import signal
import statistics
import struct
import subprocess
import sys
import termios
import time

TOKENS = [b"z", b"j", b"k", b"x"]
FLOOD_COMMAND = b"while :; do seq 1 100000; done\n"
TELAR_PREFIX = b"\x02"
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
    while True:
        remaining = end - time.perf_counter()
        if remaining <= 0:
            return
        r, _, _ = select.select([master], [], [], remaining)
        if not r:
            continue
        try:
            os.read(master, 1 << 16)
        except OSError:
            return


def drain_bytes(master, seconds):
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


CURSOR = re.compile(rb"\x1b\[(\d+);(\d+)H")


def render_visible(stream, cols):
    """Replays cursor moves and printable bytes into a text grid, enough to
    see which pane holds what after setup."""
    rows = {}
    y, x = 1, 1
    pos = 0
    for match in CURSOR.finditer(stream):
        text = ESCAPES.sub(b"", stream[pos:match.start()])
        for byte in text:
            if byte >= 0x20 and x <= cols:
                rows.setdefault(y, bytearray(b" " * cols))[x - 1] = byte
                x += 1
        y, x = int(match.group(1)), int(match.group(2))
        pos = match.end()
    return "\n".join(rows[k].decode("latin1").rstrip() for k in sorted(rows) if rows[k].strip())


def become_session_leader():
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)


def terminate(proc):
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


def open_telar_floods(master, floods):
    # Each split focuses the new pane; the flood command goes there, and the
    # final split leaves an idle pane focused for the measurement.
    for index in range(floods):
        os.write(master, TELAR_PREFIX + (b"%" if index % 2 == 0 else b'"'))
        drain(master, 0.8)
        os.write(master, FLOOD_COMMAND)
        drain(master, 0.5)
    if floods:
        os.write(master, TELAR_PREFIX + (b"%" if floods % 2 == 0 else b'"'))
        drain(master, 1.0)


def open_tmux_floods(socket_name, floods):
    for _ in range(floods):
        subprocess.run(
            ["tmux", "-L", socket_name, "split-window", "-d",
             "sh -c '" + FLOOD_COMMAND.decode().strip() + "'"],
            check=True,
        )
        # Re-tile after every split, or the focused pane runs out of room
        # for the next one.
        subprocess.run(["tmux", "-L", socket_name, "select-layout", "tiled"], check=True)
        time.sleep(0.3)
    if floods:
        time.sleep(0.5)


def measure(args, env):
    master, slave = pty.openpty()
    set_winsize(slave, args.rows, args.cols)
    proc = subprocess.Popen(
        args.cmd, stdin=slave, stdout=slave, stderr=slave, env=env,
        preexec_fn=become_session_leader, close_fds=True,
    )
    os.close(slave)
    drain(master, args.warmup)
    if proc.poll() is not None:
        raise SystemExit(f"{args.cmd[0]} exited early with {proc.returncode}")

    if args.mux == "telar":
        open_telar_floods(master, args.floods)
    else:
        open_tmux_floods(args.tmux_socket, args.floods)
    settled = drain_bytes(master, 2.0)
    if args.dump_screen:
        sys.stderr.write(render_visible(settled, args.cols) + "\n")

    latencies = []
    timeouts = 0
    for i in range(args.samples):
        token = TOKENS[i % len(TOKENS)]
        buf = b""
        t0 = time.perf_counter_ns()
        os.write(master, token)
        deadline = time.perf_counter() + 2.0
        while True:
            remaining = deadline - time.perf_counter()
            if remaining <= 0:
                timeouts += 1
                break
            r, _, _ = select.select([master], [], [], remaining)
            if not r:
                continue
            buf += os.read(master, 1 << 16)
            if token in ESCAPES.sub(b"", buf):
                latencies.append((time.perf_counter_ns() - t0) / 1e3)
                break
        # Erase the token so a later repaint of this line cannot be mistaken
        # for the next echo.
        os.write(master, b"\x7f")
        drain(master, args.gap)

    terminate(proc)
    os.close(master)
    return latencies, timeouts


def percentile(values, p):
    values = sorted(values)
    k = (len(values) - 1) * p
    lo = int(k)
    hi = min(lo + 1, len(values) - 1)
    return values[lo] + (values[hi] - values[lo]) * (k - lo)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("name")
    parser.add_argument("cmd", nargs="+")
    parser.add_argument("--mux", choices=["telar", "tmux"], required=True)
    parser.add_argument("--floods", type=int, default=0)
    parser.add_argument("--tmux-socket", default="telarbench")
    parser.add_argument("--samples", type=int, default=200)
    parser.add_argument("--gap", type=float, default=0.05)
    parser.add_argument("--rows", type=int, default=70)
    parser.add_argument("--cols", type=int, default=240)
    parser.add_argument("--warmup", type=float, default=3.0)
    parser.add_argument("--env", action="append", default=[], help="KEY=VALUE set after cleanup")
    parser.add_argument("--dump-screen", action="store_true", help="print the screen after setup")
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

    latencies, timeouts = measure(args, env)
    if not latencies:
        raise SystemExit(f"{args.name}: no samples ({timeouts} timeouts)")
    print(
        f"{args.name:14s} floods={args.floods} n={len(latencies):4d} timeouts={timeouts:3d} "
        f"p50={percentile(latencies, 0.50):8.1f}us "
        f"p95={percentile(latencies, 0.95):8.1f}us "
        f"p99={percentile(latencies, 0.99):8.1f}us "
        f"max={max(latencies):8.1f}us mean={statistics.mean(latencies):8.1f}us"
    )


if __name__ == "__main__":
    main()
