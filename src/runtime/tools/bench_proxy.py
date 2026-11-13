#!/usr/bin/env python3
"""Proxy round trips through two runtime builds, alternating paired runs.

Each run starts an isolated runtime with the proxy and its capture enabled, and
proxy-probe drives one workload through a CONNECT tunnel to a local echo origin:
proxy-latency (64-byte round trips on one tunnel), proxy-throughput (64 KiB round
trips on one tunnel) and proxy-connect (a new tunnel per round trip). Every run
must echo the same bytes, which the probe dumps and this driver compares.

    src/runtime/tools/bench_proxy.py --baseline A/telar-runtime --baseline-probe A/proxy-probe \\
        --candidate B/telar-runtime --candidate-probe B/proxy-probe --host-report host.json
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'tools'))
from benchmark_host import HostLoadGate

WORKLOADS = {'proxy-latency': 12000, 'proxy-throughput': 6000, 'proxy-connect': 300}
CONFIGURATION = 'return {api_version=2,runtime={session={persist=false},proxy={enabled=true,ca_dir="proxy",capture={enabled=true}}}}\n'


def run(runtime, probe, workload, iterations):
    with tempfile.TemporaryDirectory(prefix='telar-proxy-bench-', dir='/tmp') as directory:
        root = Path(directory)
        socket = root / 'runtime.sock'
        environment = {key: value for key, value in os.environ.items() if not key.startswith(('TELAR_', 'XDG_'))}
        for name, folder in {'HOME': 'home', 'XDG_CONFIG_HOME': 'config', 'XDG_DATA_HOME': 'data', 'XDG_STATE_HOME': 'state', 'XDG_CACHE_HOME': 'cache'}.items():
            (root / folder).mkdir()
            environment[name] = str(root / folder)
        environment['SHELL'] = '/bin/sh'
        environment['TERM'] = 'xterm-256color'
        configuration = root / 'runtime.lua'
        configuration.write_text(CONFIGURATION)
        command = [str(runtime), 'server', '--socket', str(socket), '--config', str(configuration)]
        with (root / 'runtime.log').open('w+') as log:
            server = subprocess.Popen(command, env=environment, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 30
                while not socket.exists():
                    if server.poll() is not None or time.monotonic() > deadline:
                        raise RuntimeError('Runtime did not start')
                    time.sleep(0.01)
                dump = root / 'dump.bin'
                result = subprocess.run([str(probe), str(socket), workload, str(iterations), str(dump)],
                                        env=environment, capture_output=True, text=True, timeout=300)
                if result.returncode:
                    log.seek(0)
                    raise RuntimeError(f'{probe} {workload} failed: {result.returncode}: {result.stderr}; runtime_log={log.read()}')
                return json.loads(result.stdout)['ns_per_iteration'], hashlib.sha256(dump.read_bytes()).hexdigest()
            finally:
                server.terminate()
                try:
                    server.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--baseline-probe', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--candidate-probe', type=Path, required=True)
    parser.add_argument('--pairs', type=int, default=7)
    parser.add_argument('--workload', action='append', choices=sorted(WORKLOADS))
    parser.add_argument('--host-report', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    arguments = parser.parse_args()
    if arguments.pairs < 1:
        parser.error('--pairs must be positive')

    builds = {'baseline': (arguments.baseline.resolve(), arguments.baseline_probe.resolve()),
              'candidate': (arguments.candidate.resolve(), arguments.candidate_probe.resolve())}
    gate = HostLoadGate(arguments.host_report)
    summary = {}
    samples = {}
    for workload in arguments.workload or WORKLOADS:
        iterations = WORKLOADS[workload]
        pairs = []
        for index in range(arguments.pairs):
            order = ['baseline', 'candidate'] if index % 2 == 0 else ['candidate', 'baseline']
            pair = {}
            for name in order:
                with gate.run(f'{workload}:{index}:{name}'):
                    pair[name] = run(*builds[name], workload, iterations)
            if pair['baseline'][1] != pair['candidate'][1]:
                raise RuntimeError(f'{workload}: the builds echoed different bytes')
            pairs.append({name: value[0] for name, value in pair.items()})
        ratios = [pair['candidate'] / pair['baseline'] for pair in pairs]
        summary[workload] = {
            'baseline_ns': statistics.median(pair['baseline'] for pair in pairs),
            'candidate_ns': statistics.median(pair['candidate'] for pair in pairs),
            'median_ratio': statistics.median(ratios),
            'candidate_wins': sum(ratio < 1 for ratio in ratios),
        }
        samples[workload] = pairs
        print(f"{workload}: {summary[workload]['baseline_ns']:.0f} ns -> {summary[workload]['candidate_ns']:.0f} ns, "
              f"{(summary[workload]['median_ratio'] - 1) * 100:+.1f} %, {summary[workload]['candidate_wins']}/{len(pairs)} wins", flush=True)
    gate.finish()

    if arguments.output:
        arguments.output.write_text(json.dumps({'summary': summary, 'pairs': samples}, indent=2) + '\n')


if __name__ == '__main__':
    main()
