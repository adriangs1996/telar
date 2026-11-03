#!/usr/bin/env python3
"""Four independently updating PTYs for native tab-switch qualification.

Each producer emits an identity/generation packet with a checksum. Its private
receipt links that identity to the actual runtime pane/tab/workspace environment.
This fixture does not prove a presentation endpoint; the native probe must do so.
"""
import argparse
import ctypes
import hashlib
import os
from pathlib import Path
import select
import signal
import struct
import sys
import termios
import time
import tty

from terminal_bench_fixture import Fixture, LIFETIME_SECONDS, atomic_json, defer_resize, write_all
from tab_switch_packet import DATA_CELLS, GENERATION_LIMIT, MARKER_COLUMN, MARKER_ROW, marker


TAB_COUNT = 4
UPDATES_PER_SECOND = 30
PUBLICATION = struct.Struct("<Idd")


class Timebase(ctypes.Structure):
    _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]


class ProducerClock:
    def __init__(self):
        self.system = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
        self.absolute = self.system.mach_absolute_time
        self.absolute.argtypes = []
        self.absolute.restype = ctypes.c_uint64
        timebase = self.system.mach_timebase_info
        timebase.argtypes = [ctypes.POINTER(Timebase)]
        timebase.restype = ctypes.c_int
        self.timebase = Timebase()
        if timebase(ctypes.byref(self.timebase)) or not self.timebase.numer or not self.timebase.denom:
            raise RuntimeError('cannot read producer native timebase')
        qos = self.system.qos_class_self
        qos.argtypes = []
        qos.restype = ctypes.c_uint
        self.qos = qos()
        self.native = ctypes.CDLL(str(Path(__file__).with_name('tab_switch_clock.dylib')))
        self.native.tab_switch_clock_open.argtypes = []
        self.native.tab_switch_clock_open.restype = ctypes.c_int
        self.wait = self.native.tab_switch_clock_wait
        self.wait.argtypes = [ctypes.c_int, ctypes.c_uint64]
        self.wait.restype = ctypes.c_int
        self.descriptor = self.native.tab_switch_clock_open()
        if self.descriptor < 0:
            raise RuntimeError('cannot open producer timer queue')
        os.set_inheritable(self.descriptor, False)

    def close(self):
        os.close(self.descriptor)

    def sleep_until(self, deadline):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return
        ticks = self.absolute() + int(remaining * 1e9 * self.timebase.denom / self.timebase.numer)
        status = self.wait(self.descriptor, ticks)
        if status:
            raise RuntimeError(f'native producer wait failed: {status}')


class TabFixture(Fixture):
    def __init__(self, directory):
        super().__init__(directory)
        self.generation = 0
        self.tab_index = 0 if self.primary else self.claim_tab()
        self.identities = {name: int(os.environ[name]) for name in
                           ('TELAR_PANE_ID', 'TELAR_PANE_GENERATION', 'TELAR_TAB_ID', 'TELAR_WORKSPACE_ID')}
        if any(value <= 0 for value in self.identities.values()):
            raise ValueError('fixture requires positive runtime identities')
        self.switch_directory = directory / 'switching'
        self.switch_directory.mkdir(mode=0o700, exist_ok=True)
        self.first_publication_ns = None
        self.last_publication_ns = None
        self.publications = 0
        self.payload_digest = hashlib.sha256()
        if sys.platform != 'darwin':
            raise ValueError('native tab-switch qualification requires macOS')
        self.clock = ProducerClock()
        self.media_time = ctypes.CDLL('/System/Library/Frameworks/QuartzCore.framework/QuartzCore').CACurrentMediaTime
        self.media_time.argtypes = []
        self.media_time.restype = ctypes.c_double
        self.events = os.open(self.switch_directory / f'{self.tab_index}.events',
                              os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC, 0o600)

    def claim_tab(self):
        for index in range(1, TAB_COUNT):
            try:
                descriptor = os.open(self.directory / f'tab-{index}.claim',
                                     os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            except FileExistsError:
                continue
            with os.fdopen(descriptor, 'w') as claim:
                claim.write(str(self.pid) + '\n')
            return index
        raise ValueError('too many tab fixtures')

    def record_switch(self):
        with defer_resize():
            if self.size is None:
                return
            atomic_json(self.switch_directory / f'{self.tab_index}.json', dict(
                pid=self.pid, tab_index=self.tab_index, identities=self.identities, producer_qos=self.clock.qos,
                wait_clock="kqueue_absolute_mach_critical", timebase=dict(numer=self.clock.timebase.numer, denom=self.clock.timebase.denom),
                phase=self.phase, error=self.error, generation=self.generation,
                cols=self.size.columns, rows=self.size.lines,
                first_publication_ns=self.first_publication_ns,
                last_publication_ns=self.last_publication_ns, publications=self.publications,
                offered_updates_per_second=UPDATES_PER_SECOND,
                emitted_bytes=self.emitted_bytes, payload_sha256=self.payload_digest.hexdigest()))

    def record(self):
        super().record()
        self.record_switch()

    def draw_marker(self):
        with defer_resize():
            if not self.generation:
                return
            if self.size.columns < MARKER_COLUMN + DATA_CELLS or self.size.lines < MARKER_ROW + 2:
                raise ValueError('terminal is too small for the tab packet')
            heading = f'Tab producer {self.tab_index}; generation {self.generation:05d}'
            line = f'{self.tab_index:02d}:{self.generation:05d} ' + hashlib.sha256(heading.encode()).hexdigest()
            payload = (b'\x1b[?2026h\x1b[0m\x1b[1;1H\x1b[2K' + heading.encode() +
                       f'\x1b[{MARKER_ROW + 2};1H\x1b[2K'.encode() + line[:self.size.columns - 1].encode() +
                       marker(self.tab_index, self.generation) + b'\x1b[?2026l')
            if self.capture_marker:
                payload = payload.replace(b'48;2;230;20;60', b'48;2;180;180;180', 1)
            write_all(payload)
            self.payload_digest.update(payload)
            self.emitted_bytes += len(payload)

    def publish(self):
        with defer_resize():
            if self.generation == GENERATION_LIMIT:
                raise ValueError('tab generation would wrap')
            self.generation += 1
            before_write = self.media_time()
            self.draw_marker()
            after_write = self.media_time()
            event = PUBLICATION.pack(self.generation, before_write, after_write)
            if os.write(self.events, event) != len(event):
                raise OSError("short publication event write")
            self.last_publication_ns = time.monotonic_ns()
            if self.first_publication_ns is None:
                self.first_publication_ns = self.last_publication_ns
            self.publications += 1
            self.record_switch()

    def run(self):
        original = termios.tcgetattr(0)
        stopping = False

        def stop(*_):
            nonlocal stopping
            stopping = True

        try:
            tty.setraw(0)
            signal.signal(signal.SIGWINCH, self.refresh_size)
            signal.signal(signal.SIGTERM, stop)
            signal.signal(signal.SIGHUP, stop)
            self.refresh_size()
            write_all(b'\x1b[?25l\x1b[0m\x1b[2J')
            self.phase = 'ready'
            self.publish()
            self.record()
            if self.primary:
                atomic_json(self.directory / 'primary.ready', dict(pid=self.pid))
            started = time.monotonic()
            deadline = started + 1 / UPDATES_PER_SECOND
            while time.monotonic() - started < LIFETIME_SECONDS:
                if stopping:
                    break
                self.clock.sleep_until(deadline)
                if stopping:
                    break
                readable, _, _ = select.select([0], [], [], 0)
                if readable:
                    value = os.read(0, 1024)
                    if not value:
                        break
                    if any(byte not in b'cr' for byte in value):
                        raise ValueError(f'unexpected terminal input instead of a tab action: {value!r}')
                    for byte in value:
                        self.capture_marker = byte == ord('c')
                        self.last_input = bytes([byte]).hex()
                        self.draw_marker()
                now = time.monotonic()
                if now >= deadline:
                    self.publish()
                    now = time.monotonic()
                    deadline += 1 / UPDATES_PER_SECOND
                    if deadline <= now:
                        deadline = now + 1 / UPDATES_PER_SECOND
            else:
                raise TimeoutError('tab fixture exceeded its lifetime')
        except Exception as error:
            self.phase = 'failed'
            self.error = str(error)
            raise
        finally:
            if self.phase != 'failed':
                self.phase = 'finished'
            if self.size is not None:
                self.record()
            os.close(self.events)
            self.clock.close()
            try:
                termios.tcsetattr(0, termios.TCSANOW, original)
            except termios.error:
                pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    TabFixture(args.directory.resolve()).run()


if __name__ == '__main__':
    main()
