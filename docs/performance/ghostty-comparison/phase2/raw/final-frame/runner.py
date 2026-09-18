#!/usr/bin/env python3
"""Check final-frame delivery and shutdown through a real headless Telar TUI."""
import argparse
import errno
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import termios
import time
import tty


def shared_clock_ns():
    # Python 3.9 on macOS gives monotonic_ns a process-local epoch.
    # clock_gettime uses one kernel epoch for the producer and observer.
    return time.clock_gettime_ns(time.CLOCK_MONOTONIC_RAW)


def save(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def write_all(data):
    pending = memoryview(data)
    while pending:
        count = os.write(1, pending)
        if count <= 0:
            raise BrokenPipeError(errno.EPIPE, 'PTY write made no progress')
        pending = pending[count:]


def producer(directory, cycles, flood_ms):
    signal.alarm(60)
    original = termios.tcgetattr(0)
    tty.setraw(0)
    try:
        write_all(b'\x1b[0m\x1b[2J\x1b[H\x1b[?25l')
        size = os.get_terminal_size(1)
        identity = dict(pid=os.getpid(), cols=size.columns, rows=size.lines)
        save(directory / 'producer-ready.json', identity)
        for cycle in range(cycles):
            while not (directory / f'{cycle}.ready').exists():
                time.sleep(.002)
            started = shared_clock_ns()
            deadline = started + round(flood_ms * 1_000_000)
            written = writes = 0
            write_all(b'\x1b[0m\x1b[2J\x1b[H')
            while shared_clock_ns() < deadline:
                # Every burst changes text, consumes publication credit and scrolls.
                line = f'{writes:016x} '.encode() + b'F' * 100 + b'\r\n'
                data = line * 16
                write_all(data)
                written += len(data)
                writes += 1
            final_started = shared_clock_ns()
            write_all(b'\x1b[0m\x1b[2J\x1b[H~')
            final_written = shared_clock_ns()
            save(directory / f'{cycle}.final.json', dict(
                **identity, cycle=cycle, flood_started_ns=started,
                flood_elapsed_ms=(final_started - started) / 1_000_000,
                flood_bytes=written, flood_writes=writes,
                final_started_ns=final_started, final_written_ns=final_written,
                output_after_final_bytes=0))
        save(directory / 'producer-idle.json', dict(**identity, cycles=cycles,
             before_blocking_read_ns=shared_clock_ns()))
        # No EOF: the runtime's next PTY read remains pending while output is idle.
        unexpected = os.read(0, 1)
        save(directory / 'producer-input.json', dict(bytes=unexpected.hex()))
        if unexpected:
            raise RuntimeError('unexpected input reached the idle producer')
    finally:
        try:
            termios.tcsetattr(0, termios.TCSANOW, original)
        except termios.error:
            pass


def run(args):
    repo = args.repo.resolve()
    sys.path.insert(0, str(repo / 'tools'))
    import echo_latency
    import echo_path
    import perf_e2e

    binary = str(args.binary.resolve())
    probe = str(args.probe.resolve())
    directory = args.output.resolve()
    env = perf_e2e.isolated_environment(directory)
    fixture = directory / 'fixture'
    fixture.mkdir(mode=0o700)
    config = repo / 'docs/performance/ghostty-comparison/config.lua'
    master, slave = echo_latency.pty.openpty()
    echo_latency.set_winsize(slave, 40, 160)
    oracle = echo_path.Oracle(probe)
    proc = None
    sessions = set()
    result = dict(binary=binary, probe=probe, outer_pty=[160, 40],
                  clock='clock_gettime_ns(CLOCK_MONOTONIC_RAW), shared kernel epoch',
                  python=sys.version, script=str(Path(__file__).resolve()),
                  cycles=[], deadline_ms=args.deadline_ms, flood_ms=args.flood_ms,
                  host_input_bytes=0, endpoint='producer final-write start to committed host VT marker',
                  scope='correctness check, not a latency benchmark', passed=False)
    failure = None
    host = (directory / 'host-output.bin').open('wb')

    def drain(timeout):
        if not select.select([master], [], [], timeout)[0]:
            return None
        try:
            data = os.read(master, 65536)
        except OSError as error:
            if error.errno == errno.EIO:
                raise EOFError('host PTY closed') from error
            raise
        if not data:
            raise EOFError('host PTY closed')
        host.write(data)
        oracle.feed(data)
        return shared_clock_ns()

    def quiet(seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            drain(min(.01, max(0, deadline - time.monotonic())))
            if oracle.count != 1 and not oracle.synchronized:
                raise AssertionError(f'final marker changed during idle: {oracle.count}')
        if oracle.count != 1 or oracle.synchronized:
            raise AssertionError('idle screen did not retain a committed final marker')

    try:
        command = [binary, '--config', str(config), sys.executable,
                   str(Path(__file__).resolve()), '--producer-dir', str(fixture),
                   '--cycles', str(args.cycles), '--flood-ms', str(args.flood_ms)]
        proc = subprocess.Popen(command, stdin=slave, stdout=slave, stderr=slave,
                                env=env, cwd=directory, close_fds=True,
                                preexec_fn=echo_latency.become_session_leader)
        os.close(slave)
        slave = None
        startup = time.monotonic()
        while time.monotonic() - startup < 3 or not (fixture / 'producer-ready.json').exists():
            if time.monotonic() - startup > 10:
                raise TimeoutError('producer did not become ready')
            drain(.01)
            if proc.poll() is not None:
                raise RuntimeError(f'TUI exited during setup: {proc.returncode}')
        result['producer'] = json.loads((fixture / 'producer-ready.json').read_text())
        if oracle.count != 0 or oracle.synchronized:
            raise AssertionError(f'expected empty initial marker set: {oracle.count}, sync={oracle.synchronized}')

        for cycle in range(args.cycles):
            cleared = cycle == 0
            observed = None
            receipt = None
            (fixture / f'{cycle}.ready').write_text('start through filesystem; no PTY input\n')
            watchdog = time.monotonic() + 10
            while time.monotonic() < watchdog:
                arrived = drain(.001)
                if arrived is not None and not oracle.synchronized:
                    if oracle.count == 0:
                        cleared = True
                    elif oracle.count == 1 and cleared and observed is None:
                        observed = arrived
                path = fixture / f'{cycle}.final.json'
                if receipt is None and path.exists():
                    receipt = json.loads(path.read_text())
                if receipt is not None:
                    deadline_ns = receipt['final_started_ns'] + round(args.deadline_ms * 1_000_000)
                    if observed is not None:
                        elapsed = (observed - receipt['final_started_ns']) / 1_000_000
                        record = dict(**receipt, marker_observed_ns=observed,
                                      observed_ms=elapsed, marker_count=oracle.count,
                                      synchronized=bool(oracle.synchronized), cleared_before_final=cleared)
                        result['cycles'].append(record)
                        save(directory / 'result.json', result)
                        if not 0 <= elapsed <= args.deadline_ms:
                            raise AssertionError(f'cycle {cycle}: marker latency {elapsed:.3f} ms')
                        break
                    if shared_clock_ns() > deadline_ns:
                        raise TimeoutError(f'cycle {cycle}: final marker missing after {args.deadline_ms} ms; '
                                           f'count={oracle.count}, sync={oracle.synchronized}, cleared={cleared}')
            else:
                raise TimeoutError(f'cycle {cycle}: producer did not finish its flood')
            quiet(args.quiet_ms / 1000)

        if not (fixture / 'producer-idle.json').exists():
            raise AssertionError('producer did not reach its blocking read')
        if (fixture / 'producer-input.json').exists():
            raise AssertionError('producer blocking read completed before shutdown')
        result['idle'] = json.loads((fixture / 'producer-idle.json').read_text())
        result['idle_verified_ms'] = args.quiet_ms
        result['marker_count_before_shutdown'] = oracle.count
        result['synchronized_before_shutdown'] = bool(oracle.synchronized)
    except Exception as error:
        failure = f'{type(error).__name__}: {error}'
    finally:
        try:
            roots = perf_e2e.runtime_pids(env['TELAR_SOCKET_PATH'])
            if proc is not None:
                roots.append(proc.pid)
            sessions = perf_e2e.owned_sessions(perf_e2e.descendants(roots))
            shutdown = perf_e2e.stop_runtime(binary, env)
            result['shutdown'] = shutdown
            save(directory / 'shutdown.json', shutdown)
            if not all(shutdown.get(key) for key in ('exited', 'children_exited', 'socket_removed', 'cleanup_complete')) or shutdown['returncode'] != 0:
                failure = failure or 'runtime did not shut down cleanly while output was idle'
            if proc is not None:
                until = time.monotonic() + 2
                while proc.poll() is None and time.monotonic() < until:
                    try:
                        drain(.01)
                    except EOFError:
                        break
                try:
                    proc.wait(timeout=.2)
                except subprocess.TimeoutExpired:
                    echo_latency.terminate(proc)
                result['client_returncode'] = proc.poll()
            survivors = perf_e2e.session_members(sessions)
            perf_e2e.cleanup_sessions(sessions)
            result['cleanup'] = dict(sessions=sorted(sessions), forced_cleanup=survivors,
                                     remaining=perf_e2e.session_members(sessions))
            if survivors:
                failure = failure or 'isolated sessions needed forced cleanup'
        except Exception as error:
            failure = failure or f'cleanup {type(error).__name__}: {error}'
            if proc is not None and proc.poll() is None:
                echo_latency.terminate(proc)
            if sessions:
                perf_e2e.cleanup_sessions(sessions)
        finally:
            os.close(master)
            if slave is not None:
                os.close(slave)
            host.close()
            oracle.close()
        result['passed'] = failure is None
        result['failure'] = failure
        save(directory / 'result.json', result)
        print(json.dumps(result), flush=True)
    return 0 if result['passed'] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=Path.cwd())
    parser.add_argument('--binary', type=Path, default=Path('zig-out/bin/telar'))
    parser.add_argument('--probe', type=Path, default=Path('zig-out/bin/echo-probe'))
    parser.add_argument('--output', type=Path)
    parser.add_argument('--producer-dir', type=Path)
    parser.add_argument('--cycles', type=int, default=3)
    parser.add_argument('--flood-ms', type=float, default=150)
    parser.add_argument('--deadline-ms', type=float, default=250)
    parser.add_argument('--quiet-ms', type=float, default=400)
    args = parser.parse_args()
    if not 1 <= args.cycles <= 10 or not 80 <= args.flood_ms <= 1000:
        parser.error('cycles must be 1..10 and flood-ms must be 80..1000')
    if args.deadline_ms <= 0 or args.quiet_ms <= 0:
        parser.error('deadline-ms and quiet-ms must be positive')
    if args.producer_dir:
        producer(args.producer_dir, args.cycles, args.flood_ms)
        return 0
    if args.output is None:
        parser.error('--output is required')
    return run(args)


if __name__ == '__main__':
    raise SystemExit(main())
