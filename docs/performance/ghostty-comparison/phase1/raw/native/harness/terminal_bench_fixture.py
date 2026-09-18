#!/usr/bin/env python3
"""PTY workload for native terminal comparisons, with per-process receipts.

The first process owns the alternating marker used by gui_tui_latency.m.
Other processes render neutral text and wait or flood output for at most 75 s.
Optional throughput cases end at a terminal DSR response, before GPU delivery.
They wait for the native probe to confirm geometry through viewport.ready.
"""

import argparse
import errno
import json
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
    else:
        prefix, suffix = b'\x1b[38;2;180;180;180m', b'\x1b[0m\r\n'
        line = prefix + b'benchmark text ' * 4
        line = line[:64 - len(suffix)] + suffix
    assert len(line) == 64
    return line * (CHUNK_BYTES // len(line))


class Fixture:
    def __init__(self, directory):
        self.directory = directory
        self.pid = os.getpid()
        self.background = os.environ.get('BENCH_BACKGROUND', 'idle')
        if self.background not in ('idle', 'flood'):
            raise ValueError('BENCH_BACKGROUND must be idle or flood')
        throughput = os.environ.get('BENCH_THROUGHPUT', '0')
        if throughput not in ('0', '1'):
            raise ValueError('BENCH_THROUGHPUT must be 0 or 1')
        self.throughput = throughput == '1'
        self.color = 0
        self.size = None
        self.geometry_generation = 0
        self.phase = 'starting'
        self.emitted_bytes = 0
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
        atomic_json(self.receipt, dict(pid=self.pid, ppid=os.getppid(),
                    role='primary' if self.primary else 'background',
                    background=self.background, cols=self.size.columns,
                    rows=self.size.lines, phase=self.phase,
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
                      bytes_per_case=PAYLOAD_BYTES, cases=[], failed=False)
        try:
            for name in ('ascii', 'ansi'):
                self.refresh_size()
                case_size = self.size
                case_generation = self.geometry_generation
                chunk = payload_chunk(name)
                write_all(b'\x1b[0m\x1b[2J\x1b[H\x1b[6n')
                self.await_dsr()
                started = time.perf_counter_ns()
                for _ in range(PAYLOAD_BYTES // len(chunk)):
                    write_all(chunk)
                write_all(b'\x1b[1;1H\x1b[6n')
                self.await_dsr()
                elapsed = (time.perf_counter_ns() - started) / 1e9
                if (self.geometry_generation != case_generation or self.size != case_size or
                        os.get_terminal_size(0) != case_size):
                    raise RuntimeError('PTY geometry changed during throughput measurement')
                result['cases'].append(dict(name=name, bytes=PAYLOAD_BYTES,
                                           cols=case_size.columns, rows=case_size.lines,
                                           elapsed_ms=elapsed * 1000,
                                           mib_per_second=PAYLOAD_BYTES / (1024 * 1024) / elapsed))
                atomic_json(self.directory / 'throughput.json', result)
        except Exception as error:
            result.update(failed=True, error=str(error))
            atomic_json(self.directory / 'throughput.json', result)
            raise

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
                chunk = payload_chunk('ascii')
                while True:
                    write_all(chunk)
                    self.emitted_bytes += len(chunk)
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
