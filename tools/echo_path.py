#!/usr/bin/env python3
"""Measure a single key through controlled PTYs; validate echo and erase with VT."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import select
import shlex
import socket
import struct
import subprocess
import termios
import time

import echo_latency
import perf_e2e


class Oracle:
    def __init__(self, probe):
        self.proc = subprocess.Popen([probe, 'screen', '160', '40'], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, bufsize=0)
        self.count = 0
        self.synchronized = False

    def feed(self, data):
        pending = memoryview(struct.pack('<I', len(data)) + data)
        while pending:
            written = self.proc.stdin.write(pending)
            if not written:
                raise EOFError('VT oracle input closed')
            pending = pending[written:]
        reply = b''
        while len(reply) < 8:
            if not select.select([self.proc.stdout], [], [], 2)[0]:
                raise TimeoutError('VT oracle did not reply')
            part = self.proc.stdout.read(8 - len(reply))
            if not part:
                raise RuntimeError('VT oracle exited')
            reply += part
        self.count, self.synchronized = struct.unpack('<II', reply)

    def close(self):
        self.proc.stdin.close()
        try:
            self.proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        self.proc.stdout.close()


def consume(master, oracle, duration):
    deadline = time.perf_counter() + duration
    while time.perf_counter() < deadline:
        if select.select([master], [], [], max(0, deadline - time.perf_counter()))[0]:
            oracle.feed(os.read(master, 65536))


def exchange(master, oracle, stimulus, expected):
    started = time.perf_counter_ns()
    os.write(master, stimulus)
    sent = time.perf_counter_ns()
    deadline = time.perf_counter() + 2
    wire = reads = 0
    while time.perf_counter() < deadline:
        if not select.select([master], [], [], max(0, deadline - time.perf_counter()))[0]:
            continue
        data = os.read(master, 65536)
        arrived = time.perf_counter_ns()
        if not data:
            raise EOFError('host PTY closed')
        wire += len(data)
        reads += 1
        # Timestamp before VT work. Only a committed visible change counts.
        oracle.feed(data)
        if oracle.count == expected and not oracle.synchronized:
            return dict(us=(arrived - started) / 1000, wire_bytes=wire, reads=reads,
                        started_ns=started, sent_ns=sent, arrived_ns=arrived)
    raise TimeoutError(f'expected {expected} visible tildes; got {oracle.count}, sync={oracle.synchronized}')


def measure(spec, directory, args):
    name, binary = spec
    env = perf_e2e.isolated_environment(directory)
    shell = directory / 'shell'
    command = f'{shlex.quote(args.probe)} app' if args.application else '/bin/cat'
    shell.write_text('#!/bin/sh\nexec ' + ('/bin/sh' if args.floods else command) + '\n')
    if args.floods:
        env.update(ENV='/dev/null', BASH_ENV='/dev/null', PS1='')
    shell.chmod(0o700)
    env['SHELL'] = str(shell)
    if args.trace:
        env['TELAR_ECHO_TRACE_DIR'] = str(directory)
    master, slave = echo_latency.pty.openpty()
    echo_latency.set_winsize(slave, 40, 160)
    procs = []
    oracle = Oracle(args.probe)
    sockets = []
    try:
        if name == 'direct' and not args.application:
            attrs = termios.tcgetattr(slave)
            attrs[3] |= termios.ECHO | termios.ICANON | termios.ECHOE
            termios.tcsetattr(slave, termios.TCSANOW, attrs)
        else:
            if name == 'direct':
                cmd = [args.probe, 'app']
            elif name == 'one':
                cmd = [args.probe, 'one', str(shell)]
            elif name == 'two':
                left, right = socket.socketpair()
                sockets = [left, right]
                procs.append(subprocess.Popen([args.probe, 'server', str(right.fileno()), str(shell)],
                                               pass_fds=(right.fileno(),), env=env,
                                               start_new_session=True, cwd=directory))
                cmd = [args.probe, 'client', str(left.fileno())]
            else:
                cmd = [binary, '--no-config', '--sidebar-renderer', 'cells']
            procs.append(subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=slave,
                                         pass_fds=tuple(s.fileno() for s in sockets[:1]), env=env,
                                         cwd=directory, preexec_fn=echo_latency.become_session_leader))
            os.close(slave)
            slave = None
        for channel in sockets:
            channel.close()
        consume(master, oracle, 2)
        if args.floods:
            perf_e2e.load_latency.open_telar_floods(master, args.floods,
                                                  lambda fd, seconds: consume(fd, oracle, seconds))
            os.write(master, ('exec ' + command + '\r').encode())
            consume(master, oracle, 2)
        initial = oracle.count
        samples = []
        # Verified erase, not a timed assumption, separates every sample.
        for index in range(args.samples + 20):
            sample = exchange(master, oracle, b'~', initial + 1)
            exchange(master, oracle, b'\x7f', initial)
            consume(master, oracle, args.gap)
            if index >= 20:
                samples.append(sample)
        values = [s['us'] for s in samples]
        return dict(name=name, samples=samples, **{
            label: echo_latency.percentile(values, p)
            for label, p in [('p50_us', .5), ('p95_us', .95), ('p99_us', .99), ('min_us', 0)]})
    finally:
        sessions = perf_e2e.owned_sessions(perf_e2e.descendants([proc.pid for proc in procs]))
        if binary and procs and procs[-1].poll() is None:
            os.write(master, perf_e2e.load_latency.TELAR_PREFIX + b'd')
            deadline = time.perf_counter() + 2
            while procs[-1].poll() is None and time.perf_counter() < deadline:
                # Terminal restoration can wait for its output to be consumed.
                if select.select([master], [], [], .02)[0]:
                    try:
                        data = os.read(master, 65536)
                    except OSError:
                        break
                    if data:
                        oracle.feed(data)
            try:
                procs[-1].wait(timeout=.2)
            except subprocess.TimeoutExpired:
                pass
        (directory / 'client-exit.json').write_text(json.dumps([
            dict(pid=proc.pid, returncode=proc.poll()) for proc in procs]))
        for proc in reversed(procs):
            if proc.poll() is None:
                # Close the relay client first; its server then tears down the PTY.
                if name == 'two' and proc is procs[0]:
                    try:
                        proc.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        echo_latency.terminate(proc)
                else:
                    echo_latency.terminate(proc)
        if binary:
            shutdown = perf_e2e.stop_runtime(binary, env)
            (directory / 'shutdown.json').write_text(json.dumps(shutdown))
        survivors = perf_e2e.session_members(sessions) if sessions else []
        perf_e2e.cleanup_sessions(sessions)
        (directory / 'relay-cleanup.json').write_text(json.dumps(dict(
            sessions=sorted(sessions), forced_cleanup=survivors, cleanup_complete=True)))
        os.close(master)
        if slave is not None:
            os.close(slave)
        oracle.close()


def ordered_specs(specs, repetition):
    groups = [[spec] for spec in specs if spec[1] is None]
    binaries = [spec for spec in specs if spec[1] is not None]
    if binaries:
        groups.append(list(reversed(binaries)) if repetition % 2 else binaries)
    offset = repetition % len(groups)
    return [spec for group in groups[offset:] + groups[:offset] for spec in group]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--probe', required=True)
    parser.add_argument('--baseline')
    parser.add_argument('--candidate')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--samples', type=int, default=200)
    parser.add_argument('--repetitions', type=int, default=5)
    parser.add_argument('--gap', type=float, default=.05)
    parser.add_argument('--application', action='store_true')
    parser.add_argument('--trace', action='store_true')
    parser.add_argument('--floods', type=int, choices=[0, 1, 2], default=0)
    parser.add_argument('--controls', nargs='*', default=['direct', 'one', 'two'], choices=['direct', 'one', 'two'])
    args = parser.parse_args()
    if args.samples <= 0 or args.repetitions <= 0 or not math.isfinite(args.gap) or args.gap < 0:
        parser.error('samples and repetitions must be positive; gap must be finite and nonnegative')
    if not args.controls and not args.baseline and not args.candidate:
        parser.error('select at least one control or binary')
    if args.trace and args.samples > 200:
        parser.error('traced fixtures are limited to 200 samples')
    if args.floods and (args.controls or args.trace):
        parser.error('floods require --controls with no names, and cannot use the single-pane tracer')
    if len(set(args.controls)) != len(args.controls):
        parser.error('controls must be unique')
    args.probe = str(Path(args.probe).resolve())
    args.output = args.output.resolve()
    args.output.mkdir(parents=True)
    specs = [(name, None) for name in args.controls]
    specs += [(name, str(Path(binary).resolve())) for name, binary in
              [('baseline', args.baseline), ('candidate', args.candidate)] if binary]
    paths = dict(probe=args.probe, **{name: binary for name, binary in specs if binary})
    metadata = dict(platform=platform.platform(), python=platform.python_version(),
                    samples=args.samples, repetitions=args.repetitions, gap=args.gap,
                    application=args.application, trace=args.trace, floods=args.floods, controls=args.controls,
                    binaries={name: dict(path=path, sha256=hashlib.sha256(Path(path).read_bytes()).hexdigest())
                              for name, path in paths.items()},
                    tools={name: hashlib.sha256((Path(__file__).parent / name).read_bytes()).hexdigest()
                           for name in ['echo_path.py', 'echo_latency.py', 'perf_e2e.py', 'load_latency.py']},
                    order=[[name for name, _ in ordered_specs(specs, repetition)]
                           for repetition in range(args.repetitions)])
    (args.output / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
    records = []
    for repetition in range(args.repetitions):
        for spec in ordered_specs(specs, repetition):
            record = measure(spec, args.output / f'{spec[0]}-{repetition}', args)
            record.update(repetition=repetition, application=args.application, gap=args.gap, floods=args.floods)
            records.append(record)
            (args.output / 'results.json').write_text(json.dumps(records, indent=2) + '\n')
            print(json.dumps({k: v for k, v in record.items() if k != 'samples'}), flush=True)


if __name__ == '__main__':
    main()
