#!/usr/bin/env python3
"""Real PTY round trips, isolated native daemons, alternating paired runs."""
import argparse
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import signal
import statistics
import subprocess
import tempfile
import time


def process_snapshot():
    snapshot = subprocess.check_output(['ps', '-Ao', 'comm,%cpu'], text=True)
    for line in snapshot.splitlines()[1:]:
        if Path(line.rsplit(None, 1)[0]).name in {'clang', 'clang++', 'zig', 'ninja', 'ld', 'cc1', 'cc1plus'}:
            raise RuntimeError('Concurrent build invalidates measurement: ' + line)
    return snapshot


def stop_owned_process(process):
    if process.returncode is not None:
        return {}
    process.send_signal(signal.SIGTERM)
    deadline = time.monotonic() + 5
    while True:
        pid, status, usage = os.wait4(process.pid, os.WNOHANG)
        if pid:
            process.returncode = os.waitstatus_to_exitcode(status)
            return {'user_cpu_seconds': usage.ru_utime, 'system_cpu_seconds': usage.ru_stime,
                    'maxrss_bytes_macos': usage.ru_maxrss, 'exit_code': process.returncode}
        if time.monotonic() > deadline:
            process.kill()
        time.sleep(0.005)


def run(binary, probe):
    with tempfile.TemporaryDirectory(prefix='telar-control-pty-', dir='/tmp') as directory:
        root = Path(directory)
        endpoint = root / 'runtime.sock'
        environment = {key: value for key, value in os.environ.items() if not key.startswith(('TELAR_', 'XDG_'))}
        for key in ['HOME', 'XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME', 'XDG_RUNTIME_DIR']:
            location = root / key.lower()
            location.mkdir()
            environment[key] = str(location)
        environment['TERM'] = 'xterm-256color'
        command = [str(binary), '--socket', str(endpoint), '--history', ':memory:', '--no-session', '--no-config']
        with (root / 'runtime.log').open('w+') as log:
            server = subprocess.Popen(command, env=environment, cwd=root, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 15
                while not endpoint.exists():
                    if server.poll() is not None or time.monotonic() > deadline:
                        raise RuntimeError('Owned runtime failed to start')
                    time.sleep(0.01)
                report = root / 'report.json'
                result = subprocess.run([str(probe), str(endpoint), str(report)], env=environment,
                                        capture_output=True, text=True, timeout=40)
                if result.returncode:
                    raise RuntimeError(f'Probe failed: {result.returncode}: {result.stderr}; partial={report.read_text() if report.exists() else "missing"}')
                measured = json.loads(report.read_text())
            finally:
                usage = stop_owned_process(server)
                log.seek(0)
                runtime_log = log.read()
            measured.update({'runtime_usage': usage, 'runtime_log': runtime_log, 'command': command})
            return measured


def percentile(samples, fraction):
    return sorted(samples)[math.ceil(len(samples) * fraction) - 1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--native', type=Path, required=True)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--probe', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--pairs', type=int, default=7)
    args = parser.parse_args()
    if args.pairs < 1:
        parser.error('--pairs must be positive')
    before = process_snapshot()
    started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    pairs = []
    for index in range(args.pairs):
        order = ['native', 'baseline'] if index % 2 == 0 else ['baseline', 'native']
        pair = {'order': order, 'load_before': os.getloadavg()}
        for name in order:
            pair[name] = run(getattr(args, name).resolve(), args.probe.resolve())
        pairs.append(pair)
        print('pair', index + 1, {name: pair[name]['saturation'] for name in order}, flush=True)
    summary = {}
    for case in pairs[0]['native']['cases']:
        values = {name: [sample for pair in pairs for sample in pair[name]['cases'][case]['roundtrip_ns']]
                  for name in ['native', 'baseline']}
        ratios = [statistics.median(pair['native']['cases'][case]['roundtrip_ns']) /
                  statistics.median(pair['baseline']['cases'][case]['roundtrip_ns']) for pair in pairs]
        summary[case] = {name: {'p50_ns': percentile(samples, .5), 'p95_ns': percentile(samples, .95),
                               'p99_ns': percentile(samples, .99)} for name, samples in values.items()}
        summary[case].update({'pair_median_ratios': ratios, 'median_ratio': statistics.median(ratios),
                              'native_wins': sum(ratio < 1 for ratio in ratios)})
    report = {'started_at': started, 'finished_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'platform': platform.platform(), 'architecture': platform.machine(), 'pairs': pairs, 'summary': summary,
              'hashes': {str(path.resolve()): hashlib.sha256(path.read_bytes()).hexdigest()
                         for path in [args.native, args.baseline, args.probe, Path(__file__)]},
              'processes_before': before, 'processes_after': process_snapshot(),
              'scope': 'Actual PTY child write through runtime to PTY child read. Baseline is original Telar C++ runtime, not Ghostty application. Burst latency is per 32-response round trip. Byte writes may coalesce in kernel.',
              'limits': ['No per-query allocations/copy counts; runtime maxrss covers its full lifetime including initialization.',
                         'Parent performs ReadPane every 2ms to drain/ack UI frames; this is part of both workloads.',
                         'Saturation counts replies after a 100ms read pause; child_write_eagain counts child output writes, not runtime writev calls.',
                         'Counter-based reply completion is a latency marker; byte-exact semantics are checked separately.',
                         'CPU/RSS accounting from wait4 covers only the owned runtime process, excluding probe, pane child and other sessions.']}
    args.output.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
