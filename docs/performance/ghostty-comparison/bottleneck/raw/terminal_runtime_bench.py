#!/usr/bin/env python3
"""Run the existing DSR workload inside an isolated, headless Telar TUI."""
import argparse
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import time

TOOLS = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS))
import flood
import perf_e2e


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--mib', type=int, default=8)
    parser.add_argument('--sample', action='store_true')
    parser.add_argument('--detach', action='store_true')
    args = parser.parse_args()
    directory = args.output.resolve()
    env = perf_e2e.isolated_environment(directory)
    env.update(BENCH_THROUGHPUT='1', BENCH_BACKGROUND='idle')
    fixture = directory / 'fixture'
    fixture.mkdir(mode=0o700)
    child = directory / 'workload.py'
    child.write_text('import sys\nfrom pathlib import Path\n'
                     f'sys.path.insert(0, {str(TOOLS)!r})\n'
                     'import terminal_bench_fixture as fixture\n'
                     f'fixture.PAYLOAD_BYTES = {args.mib} * 1024 * 1024\n'
                     'fixture.LIFETIME_SECONDS = 180\n'
                     f'fixture.Fixture(Path({str(fixture)!r})).run()\n')
    master, slave = flood.pty.openpty()
    flood.set_winsize(slave, 35, 111)
    config = TOOLS.parent / 'docs/performance/ghostty-comparison/config.lua'
    proc = subprocess.Popen([args.binary, '--config', str(config), sys.executable, str(child)],
                            stdin=slave, stdout=slave, stderr=slave, env=env,
                            cwd=directory, preexec_fn=flood.become_session_leader,
                            close_fds=True)
    os.close(slave)
    profiles = []
    started = time.monotonic()
    released = False
    host_bytes = 0
    detach_sent = False
    result = None
    try:
        with (directory / 'host-output.bin').open('wb') as host:
            while time.monotonic() - started < 150:
                if args.detach and proc.poll() is not None:
                    time.sleep(.02)
                    readable = []
                else:
                    readable, _, _ = select.select([master], [], [], .02)
                if readable:
                    try:
                        data = os.read(master, 65536)
                    except OSError:
                        data = b''
                    host.write(data)
                    host_bytes += len(data)
                receipts = list((fixture / 'receipts').glob('*.json'))
                ready = receipts and json.loads(receipts[0].read_text()).get('phase') == 'awaiting_viewport'
                if ready and not released and time.monotonic() - started > 3:
                    pids = perf_e2e.runtime_pids(env['TELAR_SOCKET_PATH'])
                    assert len(pids) == 1, pids
                    (directory / 'runtime.pid').write_text(str(pids[0]))
                    if args.detach and not detach_sent:
                        os.write(master, b'\x02d')
                        detach_sent = True
                    if not args.detach or proc.poll() is not None:
                        if args.sample:
                            for label, pid in [('runtime', pids[0]), ('client', proc.pid)]:
                                if label == 'client' and args.detach:
                                    continue
                                log = (directory / f'{label}-sample.log').open('wb')
                                profiles.append((subprocess.Popen(['/usr/bin/sample', str(pid), '8', '1', '-file', str(directory / f'{label}-sample.txt')], stdout=log, stderr=log), log))
                        (fixture / 'viewport.ready').write_text('headless diagnostic; no native probe\n')
                        released = True
                        print(json.dumps(dict(phase='running', runtime_pid=pids[0], client_pid=proc.pid, directory=str(directory))), flush=True)
                output = fixture / 'throughput.json'
                if output.exists():
                    result = json.loads(output.read_text())
                    if result.get('failed') or len(result.get('cases', [])) == 2:
                        break
                if proc.poll() is not None and not args.detach:
                    raise RuntimeError(f'client exited early: {proc.returncode}')
        if result is None or len(result.get('cases', [])) != 2 or result.get('failed'):
            raise RuntimeError(f'incomplete workload: {result}')
        result.update(binary=args.binary, sampled=args.sample, detached=args.detach,
                      host_bytes=host_bytes, outer_pty=[111, 35])
        (directory / 'result.json').write_text(json.dumps(result, indent=2)+'\n')
        print(json.dumps(result), flush=True)
    finally:
        for profiler, log in profiles:
            profiler.wait(timeout=15)
            log.close()
        (directory / 'shutdown.json').write_text(json.dumps(perf_e2e.stop_runtime(args.binary, env), indent=2))
        if proc.poll() is None:
            flood.terminate(proc)
        os.close(master)


if __name__ == '__main__':
    main()
