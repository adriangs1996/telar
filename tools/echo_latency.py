#!/usr/bin/env python3
"""Keystroke-to-echo latency through a terminal multiplexer.

Spawns the multiplexer inside a controlled pty whose shell is `cat`. Each
sample writes a two-byte token to the pty master, then measures the time until
that token appears in the multiplexer's output. The inner pty's line discipline
echoes the token immediately, so the measured time is the multiplexer's own
pty-read -> emulate -> render -> host-write pipeline.

telar is measured through its headless client (`--headless`): each token is
a `text` line and the latency runs from the client taking the line to the
client presenting the first frame of that pane, read from its exit trace.
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
import tempfile
import time
from pathlib import Path

import headless_client

TOKENS = [b"zq", b"qz", b"xz", b"zx", b"jq", b"qj", b"kz", b"zk"]
SINGLE = [b"z", b"j", b"k", b"x"]

# Cursor moves and attribute changes between the token's bytes are not
# missing bytes; the multiplexer may paint the token in two frames.
ESCAPES = re.compile(
    rb"\x1b\[[0-?]*[ -/]*[@-~]"  # CSI
    rb"|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"  # OSC
    rb"|\x1bP[^\x1b]*\x1b\\"  # DCS
    rb"|\x1b[@-Z\\-_]"  # two-byte
)


def visible(buf):
    return ESCAPES.sub(b"", buf)


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


def measure(cmd, env, samples, gap, rows, cols, warmup, tokens):
    master, slave = pty.openpty()
    set_winsize(slave, rows, cols)
    proc = subprocess.Popen(
        cmd,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        env=env,
        preexec_fn=become_session_leader,
        close_fds=True,
    )
    os.close(slave)
    banner = drain(master, warmup)
    if proc.poll() is not None:
        sys.stderr.write(banner.decode("utf-8", "replace"))
        raise SystemExit(f"{cmd[0]} exited early with {proc.returncode}")

    latencies = []
    timeouts = 0
    for i in range(samples):
        token = tokens[i % len(tokens)]
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
            if token in visible(buf):
                latencies.append((time.perf_counter_ns() - t0) / 1e3)
                break
        # Erase the token so a later repaint of this line cannot be mistaken
        # for the next echo.
        os.write(master, b"\x7f" * len(token))
        drain(master, gap)

    terminate(proc)
    os.close(master)
    return latencies, timeouts


def measure_headless(binary, env, samples, gap, rows, cols, warmup, tokens, directory):
    """Echo latency through telar-headless in `directory`, which receives the
    client's trace and log."""
    directory = Path(directory)
    client = headless_client.HeadlessClient(
        ["--no-config"], env=env, cwd=directory, size=(cols, rows),
        trace=directory / "headless-trace.json", log=directory / "headless.log",
        binary=binary,
    )
    try:
        client.wait_ready()
        time.sleep(warmup)
        if not client.running():
            raise SystemExit(f"{binary} exited early: {(directory / 'headless.log').read_text()}")
        client.mark("measure")
        for i in range(samples):
            token = tokens[i % len(tokens)].decode()
            client.text(token)
            time.sleep(gap)
            # Erase the token so the next echo lands on a quiet line.
            client.send(*["key backspace"] * len(token))
            time.sleep(gap)
        if client.quit() != 0:
            raise SystemExit(f"{binary} failed: {(directory / 'headless.log').read_text()}")
    finally:
        client.terminate()
    return headless_client.echo_latencies(client.trace(), since="measure")


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
    parser.add_argument("--samples", type=int, default=300)
    parser.add_argument("--gap", type=float, default=0.03)
    parser.add_argument("--rows", type=int, default=40)
    parser.add_argument("--cols", type=int, default=160)
    parser.add_argument("--warmup", type=float, default=3.0)
    parser.add_argument("--shell", required=True, help="path of the cat shell")
    parser.add_argument("--env", action="append", default=[], help="KEY=VALUE set after cleanup")
    parser.add_argument("--single", action="store_true", help="one-byte tokens")
    parser.add_argument("--headless", action="store_true",
                        help="cmd[0] is telar-headless; measure through its trace")
    parser.add_argument("--work", help="directory for the headless client's trace and log")
    args = parser.parse_args()

    env = dict(os.environ)
    env["SHELL"] = args.shell
    env["TERM"] = "xterm-256color"
    for key in list(env):
        if key.startswith("TELAR_") or key.startswith("TMUX") or key.startswith("HERDR"):
            del env[key]
    for pair in args.env:
        key, _, value = pair.partition("=")
        env[key] = value

    tokens = SINGLE if args.single else TOKENS
    if args.headless:
        work = args.work or tempfile.mkdtemp(prefix="telar-echo-")
        latencies, timeouts = measure_headless(
            args.cmd[0], env, args.samples, args.gap, args.rows, args.cols,
            args.warmup, tokens, work,
        )
    else:
        latencies, timeouts = measure(
            args.cmd, env, args.samples, args.gap, args.rows, args.cols, args.warmup,
            tokens,
        )
    if not latencies:
        raise SystemExit(f"{args.name}: no samples ({timeouts} timeouts)")
    print(
        f"{args.name:8s} n={len(latencies):4d} timeouts={timeouts:3d} "
        f"p50={percentile(latencies, 0.50):8.1f}us "
        f"p95={percentile(latencies, 0.95):8.1f}us "
        f"p99={percentile(latencies, 0.99):8.1f}us "
        f"min={min(latencies):8.1f}us max={max(latencies):8.1f}us "
        f"mean={statistics.mean(latencies):8.1f}us"
    )


if __name__ == "__main__":
    main()
