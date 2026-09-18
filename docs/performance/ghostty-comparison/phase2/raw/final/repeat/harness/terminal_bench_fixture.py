#!/usr/bin/env python3
"""PTY workload for native terminal comparisons, with per-process receipts.

The first process owns the alternating marker used by gui_tui_latency.m.
Other processes render neutral text and wait or flood output for at most 75 s.
BENCH_TEXT_PATTERN=variable changes every 64-byte line deterministically.
BENCH_BACKGROUND_MIB_PER_SECOND limits each background producer independently.
Optional throughput cases end at a terminal DSR response, before GPU delivery.
They wait for the native probe to confirm geometry through viewport.ready.
"""

import argparse
import errno
import hashlib
import json
import math
import os
from pathlib import Path
import re
import select
import signal
import termios
import time
import tty


PAYLOAD_BYTES = 8 * 1024 * 1024
CHUNK_BYTES = 64 * 1024
LIFETIME_SECONDS = 75
LINE_BYTES = 64
BACKGROUND_TICK_SECONDS = .005
BACKGROUND_RECEIPT_SECONDS = .5
MAX_BACKGROUND_MIB_PER_SECOND = 1024
MIN_BACKGROUND_MIB_PER_SECOND = 1 / 1024
DSR_RESPONSE = re.compile(rb'\x1b\[(\d+);(\d+)R')


def write_all(data):
    pending = memoryview(data)
    while pending:
        sent = os.write(1, pending)
        if sent == 0:
            raise BrokenPipeError(errno.EPIPE, 'PTY write made no progress')
        pending = pending[sent:]


def atomic_json(path, value):
    # SIGWINCH records geometry too; defer it until this replacement is done.
    previous = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGWINCH})
    try:
        temporary = path.with_name(path.name + f'.{os.getpid()}.tmp')
        temporary.write_text(json.dumps(value) + '\n')
        temporary.replace(path)
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous)


def payload_chunk(name):
    if name == 'ascii':
        line = b'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789\r\n'
    elif name == 'ansi':
        prefix, suffix = b'\x1b[38;2;180;180;180m', b'\x1b[0m\r\n'
        line = prefix + b'benchmark text ' * 4
        line = line[:LINE_BYTES - len(suffix)] + suffix
    else:
        raise ValueError(f'unknown payload: {name}')
    assert len(line) == LINE_BYTES
    return line * (CHUNK_BYTES // len(line))


def payload_chunks(name, pattern, total_bytes):
    if pattern not in ('repeat', 'variable'):
        raise ValueError('text pattern must be repeat or variable')
    if total_bytes <= 0 or total_bytes % LINE_BYTES:
        raise ValueError('payload bytes must be a positive multiple of 64')
    repeated = payload_chunk(name)
    prefix = b'\x1b[38;2;180;180;180m' if name == 'ansi' else b''
    suffix = b'\x1b[0m\r\n' if name == 'ansi' else b'\r\n'
    text_bytes = LINE_BYTES - len(prefix) - len(suffix)
    chunks = []
    for offset in range(0, total_bytes, CHUNK_BYTES):
        length = min(CHUNK_BYTES, total_bytes - offset)
        if pattern == 'repeat':
            chunks.append(repeated[:length])
            continue
        # Build the corpus before timing, so text generation is not a throughput limit.
        lines = [prefix + hashlib.sha256(f'telar-bench:{index}'.encode()).hexdigest().encode()[:text_bytes] + suffix
                 for index in range(offset // LINE_BYTES, (offset + length) // LINE_BYTES)]
        chunks.append(b''.join(lines))
    return tuple(chunks)


def background_rate(value):
    if value is None:
        return None
    rate = float(value)
    if not math.isfinite(rate) or not MIN_BACKGROUND_MIB_PER_SECOND <= rate <= MAX_BACKGROUND_MIB_PER_SECOND:
        raise ValueError(f'background MiB/s must be finite and within [{MIN_BACKGROUND_MIB_PER_SECOND}, {MAX_BACKGROUND_MIB_PER_SECOND}]')
    return rate


class OutputPacer:
    def __init__(self, mib_per_second):
        self.bytes_per_second = mib_per_second * 1024 * 1024
        self.block_bytes = min(CHUNK_BYTES, max(LINE_BYTES,
                               int(self.bytes_per_second * BACKGROUND_TICK_SECONDS) // LINE_BYTES * LINE_BYTES))
        self.deadline = time.monotonic()

    def wait(self):
        delay = self.deadline - time.monotonic()
        if delay > 0:
            time.sleep(delay)

    def advance(self, emitted_bytes):
        # A missed slot is dropped, so a stalled writer cannot catch up with a burst.
        interval = emitted_bytes / self.bytes_per_second
        next_deadline = self.deadline + interval
        now = time.monotonic()
        self.deadline = next_deadline if next_deadline > now else now + interval


class Fixture:
    def __init__(self, directory):
        self.directory = directory
        self.pid = os.getpid()
        self.background = os.environ.get('BENCH_BACKGROUND', 'idle')
        if self.background not in ('idle', 'flood'):
            raise ValueError('BENCH_BACKGROUND must be idle or flood')
        self.text_pattern = os.environ.get('BENCH_TEXT_PATTERN', 'repeat')
        if self.text_pattern not in ('repeat', 'variable'):
            raise ValueError('BENCH_TEXT_PATTERN must be repeat or variable')
        self.background_mib_per_second = background_rate(os.environ.get('BENCH_BACKGROUND_MIB_PER_SECOND'))
        if self.background_mib_per_second is not None and self.background != 'flood':
            raise ValueError('BENCH_BACKGROUND_MIB_PER_SECOND requires BENCH_BACKGROUND=flood')
        throughput = os.environ.get('BENCH_THROUGHPUT', '0')
        if throughput not in ('0', '1'):
            raise ValueError('BENCH_THROUGHPUT must be 0 or 1')
        self.throughput = throughput == '1'
        self.color = 0
        self.size = None
        self.geometry_generation = 0
        self.phase = 'starting'
        self.emitted_bytes = 0
        self.background_started_ns = None
        self.background_last_write_ns = None
        self.background_max_write_ns = 0
        self.background_progress = []
        self.marker_inputs = 0
        self.last_input = None
        self.error = None
        (directory / 'receipts').mkdir(mode=0o700, parents=True, exist_ok=True)
        self.receipt = directory / 'receipts' / f'{self.pid}.json'
        try:
            claim = os.open(directory / 'primary.claim', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            self.primary = False
        else:
            self.primary = True
            with os.fdopen(claim, 'w') as file:
                file.write(str(self.pid) + '\n')

    def record(self):
        elapsed = ((self.background_last_write_ns - self.background_started_ns) / 1e9
                   if self.background_last_write_ns is not None else 0)
        atomic_json(self.receipt, dict(pid=self.pid, ppid=os.getppid(),
                    role='primary' if self.primary else 'background',
                    background=self.background, cols=self.size.columns,
                    rows=self.size.lines, phase=self.phase,
                    text_pattern=self.text_pattern, background_mib_per_second=self.background_mib_per_second,
                    background_started_ns=self.background_started_ns,
                    background_last_write_ns=self.background_last_write_ns,
                    background_max_write_ms=self.background_max_write_ns / 1e6,
                    background_elapsed_seconds=elapsed,
                    background_actual_mib_per_second=self.emitted_bytes / (1024 * 1024) / elapsed if elapsed else None,
                    background_progress=self.background_progress,
                    geometry_generation=self.geometry_generation, marker_inputs=self.marker_inputs,
                    last_input=self.last_input,
                    emitted_bytes=self.emitted_bytes, error=self.error))

    def refresh_size(self, *signal_args):
        current = os.get_terminal_size(0)
        if current == self.size and not signal_args:
            return
        self.size = current
        self.geometry_generation += 1
        if self.primary:
            atomic_json(self.directory / 'size.json', [current.columns, current.lines])
            if self.phase in ('ready', 'awaiting_viewport'):
                write_all(b'\x1b[2J')
                self.draw_marker()
        self.record()

    def draw_marker(self):
        rgb = '230;20;60' if self.color == 0 else '20;220;200'
        write_all((f'\x1b[?25l\x1b[{min(8, self.size.lines)};'
                   f'{min(20, self.size.columns)}H\x1b[48;2;{rgb}m '
                   '\x1b[0m\x1b[H').encode())

    def draw_background(self):
        width = max(1, self.size.columns - 1)
        text = b'background terminal benchmark '
        row = (text * (width // len(text) + 1))[:width]
        write_all(b'\x1b[?25l\x1b[38;2;180;180;180m\x1b[H' +
                  b'\r\n'.join([row] * max(1, self.size.lines - 1)) + b'\x1b[0m')

    def await_dsr(self):
        deadline = time.monotonic() + 15
        received = b''
        while time.monotonic() < deadline:
            readable, _, _ = select.select([0], [], [], max(0, deadline - time.monotonic()))
            if not readable:
                break
            part = os.read(0, 1024)
            if not part:
                raise EOFError('PTY closed while waiting for DSR')
            received = (received + part)[-4096:]
            match = DSR_RESPONSE.search(received)
            if match:
                if tuple(map(int, match.groups())) != (1, 1):
                    raise RuntimeError(f'unexpected DSR response: {match.group()!r}')
                return
        raise TimeoutError('terminal did not answer the DSR query within 15 seconds')

    def await_viewport(self):
        self.phase = 'awaiting_viewport'
        self.draw_marker()
        self.record()
        deadline = time.monotonic() + 25
        while not (self.directory / 'viewport.ready').is_file():
            if time.monotonic() >= deadline:
                raise TimeoutError('native probe did not confirm the viewport within 25 seconds')
            time.sleep(.02)
        self.refresh_size()

    def measure_throughput(self):
        self.phase = 'throughput'
        self.record()
        result = dict(endpoint='pty_write_to_dsr_response',
                      bytes_per_case=PAYLOAD_BYTES, text_pattern=self.text_pattern, cases=[], failed=False)
        try:
            for name in ('ascii', 'ansi'):
                self.refresh_size()
                case_size = self.size
                case_generation = self.geometry_generation
                chunks = payload_chunks(name, self.text_pattern, PAYLOAD_BYTES)
                digest = hashlib.sha256()
                for chunk in chunks:
                    digest.update(chunk)
                write_all(b'\x1b[0m\x1b[2J\x1b[H\x1b[6n')
                self.await_dsr()
                started = time.perf_counter_ns()
                for chunk in chunks:
                    write_all(chunk)
                write_all(b'\x1b[1;1H\x1b[6n')
                self.await_dsr()
                elapsed = (time.perf_counter_ns() - started) / 1e9
                if (self.geometry_generation != case_generation or self.size != case_size or
                        os.get_terminal_size(0) != case_size):
                    raise RuntimeError('PTY geometry changed during throughput measurement')
                result['cases'].append(dict(name=name, bytes=PAYLOAD_BYTES,
                                           text_pattern=self.text_pattern, payload_sha256=digest.hexdigest(),
                                           cols=case_size.columns, rows=case_size.lines,
                                           elapsed_ms=elapsed * 1000,
                                           mib_per_second=PAYLOAD_BYTES / (1024 * 1024) / elapsed))
                atomic_json(self.directory / 'throughput.json', result)
        except Exception as error:
            result.update(failed=True, error=str(error))
            atomic_json(self.directory / 'throughput.json', result)
            raise

    def flood_background(self):
        chunks = payload_chunks('ascii', self.text_pattern,
                                PAYLOAD_BYTES if self.text_pattern == 'variable' else CHUNK_BYTES)
        pacer = OutputPacer(self.background_mib_per_second) if self.background_mib_per_second else None
        if pacer is None:
            while True:
                for chunk in chunks:
                    write_all(chunk)
                    self.emitted_bytes += len(chunk)
        self.background_started_ns = time.monotonic_ns()
        next_receipt = self.background_started_ns + int(BACKGROUND_RECEIPT_SECONDS * 1e9)
        while True:
            for chunk in chunks:
                for offset in range(0, len(chunk), pacer.block_bytes):
                    block = memoryview(chunk)[offset:offset + pacer.block_bytes]
                    pacer.wait()
                    started = time.monotonic_ns()
                    write_all(block)
                    self.background_last_write_ns = time.monotonic_ns()
                    self.background_max_write_ns = max(self.background_max_write_ns,
                                                       self.background_last_write_ns - started)
                    self.emitted_bytes += len(block)
                    pacer.advance(len(block))
                    if self.background_last_write_ns >= next_receipt:
                        self.background_progress.append(dict(at_ns=self.background_last_write_ns,
                                                             emitted_bytes=self.emitted_bytes))
                        self.record()
                        next_receipt = self.background_last_write_ns + int(BACKGROUND_RECEIPT_SECONDS * 1e9)

    def run(self):
        original = termios.tcgetattr(0)

        def expired(*_):
            raise TimeoutError(f'fixture reached its {LIFETIME_SECONDS}-second lifetime limit')

        def stop(*_):
            raise SystemExit(0)

        try:
            tty.setraw(0)
            signal.signal(signal.SIGWINCH, self.refresh_size)
            signal.signal(signal.SIGALRM, expired)
            signal.signal(signal.SIGTERM, stop)
            signal.signal(signal.SIGHUP, stop)
            signal.alarm(LIFETIME_SECONDS)
            self.refresh_size()
            write_all(b'\x1b[?25l\x1b[2J')
            if self.primary:
                if self.throughput:
                    self.await_viewport()
                    self.measure_throughput()
                write_all(b'\x1b[0m\x1b[2J')
                self.draw_marker()
            else:
                self.draw_background()
            self.phase = 'ready'
            self.record()
            if self.primary:
                atomic_json(self.directory / 'primary.ready', dict(pid=self.pid))
            if not self.primary and self.background == 'flood':
                self.flood_background()
            while True:
                key = os.read(0, 1)
                if not key:
                    break
                if self.primary and key in (b'x', b'r'):
                    self.last_input = key.hex()
                    if key == b'x':
                        self.marker_inputs += 1
                        self.color ^= 1
                    self.draw_marker()
        except Exception as error:
            if isinstance(error, OSError) and error.errno in (errno.EIO, errno.EPIPE):
                try:
                    completed = json.loads((self.directory / 'result.json').read_text())
                except (OSError, ValueError):
                    completed = None
                if completed and completed.get('failed') == 0 and completed.get('gpu_ms'):
                    return
            self.phase = 'failed'
            self.error = str(error)
            raise
        finally:
            signal.alarm(0)
            if self.phase != 'failed':
                self.phase = 'finished'
            if self.size is not None:
                self.record()
            try:
                termios.tcsetattr(0, termios.TCSANOW, original)
            except termios.error:
                pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    Fixture(args.directory.resolve()).run()


if __name__ == '__main__':
    main()
