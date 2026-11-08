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


def build_processes(snapshot):
    result = []
    for line in snapshot.splitlines()[1:]:
        if Path(line.rsplit(None, 1)[0]).name in {'clang', 'clang++', 'clang-tidy', 'zig', 'cmake', 'ninja', 'make', 'ld', 'ld.lld', 'cc1', 'cc1plus', 'gcc', 'g++', 'cc', 'c++'}:
            result.append(line)
    return result


def process_snapshot(reject_builds=True):
    snapshot = subprocess.check_output(['ps', '-Ao', 'ucomm,%cpu'], text=True)
    if reject_builds and (compilers := build_processes(snapshot)):
        raise RuntimeError('Concurrent build invalidates measurement: ' + repr(compilers))
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


def run(binary, probe, allow_loss=False):
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
                    log.flush()
                    log.seek(0)
                    details = log.read()
                    raise RuntimeError(f'Probe failed: {result.returncode}: {result.stderr}; partial={report.read_text() if report.exists() else "missing"}; runtime_log={details}')
                measured = json.loads(report.read_text())
                saturation = measured['saturation']
                if saturation['queries'] != 5000 or saturation['expected_bytes'] != 20000:
                    raise RuntimeError('Unexpected saturation workload')
                if not saturation['byte_exact'] or saturation['received_bytes'] != saturation['received'] * 4:
                    raise RuntimeError('Malformed or incomplete saturation response bytes')
                if saturation['complete'] != (saturation['received'] == saturation['queries']):
                    raise RuntimeError('Inconsistent saturation completion report')
                if not allow_loss and not saturation['complete']:
                    raise RuntimeError('Lost admitted saturation replies: ' + str(saturation))
                if saturation['recovery_replies'] != 1:
                    raise RuntimeError('PTY did not recover after saturation')
                for name, case in measured['cases'].items():
                    if case['warmup_ns'] < 150_000_000 or case['warmup_roundtrips'] < 1:
                        raise RuntimeError('Insufficient PTY warmup')
                    if name.startswith('graphics-png-') and not case.get('reply_byte_exact', False):
                        raise RuntimeError('PNG PTY workload did not validate the complete reply')
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
    parser.add_argument('--baseline-probe', type=Path, help='Same child workload built against the original baseline wire headers')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--pairs', type=int, default=7)
    parser.add_argument('--allow-baseline-loss', action='store_true', help='Explicitly retain the defective original baseline; native still requires all5000 byte-exact replies')
    args = parser.parse_args()
    if args.pairs < 1:
        parser.error('--pairs must be positive')
    before = process_snapshot()
    started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    pairs = []
    observations = []
    for index in range(args.pairs):
        order = ['native', 'baseline'] if index % 2 == 0 else ['baseline', 'native']
        pair = {'order': order, 'load_before': os.getloadavg()}
        for name in order:
            observations.append({'pair': index + 1, 'variant': name, 'position': 'before',
                                 'builds': build_processes(process_snapshot(False))})
            probe = args.baseline_probe if name == 'baseline' and args.baseline_probe else args.probe
            pair[name] = run(getattr(args, name).resolve(), probe.resolve(), allow_loss=name == 'baseline' and args.allow_baseline_loss)
            observations.append({'pair': index + 1, 'variant': name, 'position': 'after',
                                 'builds': build_processes(process_snapshot(False))})
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
        if len(ratios) >= 7:
            logs = [math.log(ratio) for ratio in ratios]
            center = statistics.mean(logs)
            half = 2.447 * statistics.stdev(logs) / math.sqrt(len(logs))
            interval = [math.exp(center - half), math.exp(center + half)]
            summary[case]['ratio_95pct_t_interval'] = interval
            summary[case]['status'] = ('regression' if interval[0] > 1.05 else
                                      'improvement' if interval[1] < .95 else
                                      'equivalent_within_5_percent' if interval[0] >= .95 and interval[1] <= 1.05 else
                                      'inconclusive')
    after = process_snapshot(False)
    invalid = bool(build_processes(after)) or any(item['builds'] for item in observations)
    if invalid:
        for case in summary.values():
            case['status'] = 'invalid_concurrent_build'
    report = {'started_at': started, 'finished_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'platform': platform.platform(), 'baseline_loss_explicitly_allowed': args.allow_baseline_loss,
              'native_saturation_requires_all_replies': True, 'warmup_minimum_ns_per_variant_per_case': 150_000_000, 'architecture': platform.machine(), 'pairs': pairs, 'summary': summary,
              'hashes': {str(path.resolve()): hashlib.sha256(path.read_bytes()).hexdigest()
                         for path in [args.native, args.baseline, args.probe, *( [args.baseline_probe] if args.baseline_probe else []), Path(__file__)]},
              'processes_before': before, 'processes_after': after,
              'valid_timing': not invalid, 'build_observations': observations,
              'observation_scope': 'Snapshots before and after every owned runtime, outside its measured workload. Short builds between snapshots may escape observation.',
              'scope': 'Actual PTY child write through runtime to PTY child read. Baseline is original Telar C++ runtime, not Ghostty application. Burst latency is per 32-response round trip. Byte writes may coalesce in kernel.',
              'limits': ['No per-query allocations/copy counts; runtime maxrss covers its full lifetime including initialization.',
                         'Parent performs ReadPane every 2ms to drain/ack UI frames; this is part of both workloads.',
                         'Saturation validates every byte of complete CSI0n replies after a100ms read pause and requires5000 native replies; child_write_eagain counts child output writes, not runtime writev calls.',
                         'PNG latency workloads require complete byte-exact OK replies; other latency workloads use final-byte markers. Saturation and recovery check complete response bytes; other semantics are checked separately.',
                         'CPU/RSS accounting from wait4 covers only the owned runtime process, excluding probe, pane child and other sessions.']}
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    if invalid:
        raise RuntimeError('Concurrent build invalidates timing; raw samples preserved at ' + str(args.output))


if __name__ == '__main__':
    main()
