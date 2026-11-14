#!/usr/bin/env python3
"""Tap plugin exchanges through two runtime builds, alternating paired runs.

plugin-exchange-probe starts the plugin service with one tap plugin, whose worker is
`telar-runtime tap-worker`, and times exchanges one at a time: the service hands each
to its worker thread, which encodes it for the plugin's process and publishes the
notification the plugin replies with. Every run must deliver the same effect frames,
which the probe dumps and this driver compares.

    src/runtime/tools/bench_plugin_exchange.py --baseline A/telar-runtime --baseline-probe A/plugin-exchange-probe \\
        --candidate B/telar-runtime --candidate-probe B/plugin-exchange-probe --host-report host.json
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

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'tools'))
from benchmark_host import HostLoadGate

ITERATIONS = 4000
PLUGIN = """return {on_exchange = function(exchange)
  return {telar.effect.notification{title = exchange.method .. ' ' .. exchange.target, message = exchange.host .. ' ' .. tostring(exchange.status)}}
end}
"""


def run(runtime, probe, iterations):
    with tempfile.TemporaryDirectory(prefix='telar-plugin-bench-', dir='/tmp') as directory:
        root = Path(directory)
        entry = root / 'main.lua'
        entry.write_text(PLUGIN)
        dump = root / 'dump.bin'
        environment = {key: value for key, value in os.environ.items() if not key.startswith(('TELAR_', 'XDG_'))}
        result = subprocess.run([str(probe), str(entry), str(runtime), str(iterations), str(dump)],
                                env=environment, capture_output=True, text=True, timeout=300)
        if result.returncode:
            raise RuntimeError(f'{probe} failed: {result.returncode}: {result.stderr}')
        return json.loads(result.stdout)['ns_per_iteration'], hashlib.sha256(dump.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--baseline-probe', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--candidate-probe', type=Path, required=True)
    parser.add_argument('--pairs', type=int, default=7)
    parser.add_argument('--iterations', type=int, default=ITERATIONS)
    parser.add_argument('--host-report', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    arguments = parser.parse_args()
    if arguments.pairs < 1 or arguments.iterations < 1:
        parser.error('--pairs and --iterations must be positive')

    builds = {'baseline': (arguments.baseline.resolve(), arguments.baseline_probe.resolve()),
              'candidate': (arguments.candidate.resolve(), arguments.candidate_probe.resolve())}
    gate = HostLoadGate(arguments.host_report)
    pairs = []
    for index in range(arguments.pairs):
        order = ['baseline', 'candidate'] if index % 2 == 0 else ['candidate', 'baseline']
        pair = {}
        for name in order:
            with gate.run(f'plugin-exchange:{index}:{name}'):
                pair[name] = run(*builds[name], arguments.iterations)
        if pair['baseline'][1] != pair['candidate'][1]:
            raise RuntimeError('plugin-exchange: the builds delivered different effects')
        pairs.append({name: value[0] for name, value in pair.items()})
    gate.finish()

    ratios = [pair['candidate'] / pair['baseline'] for pair in pairs]
    summary = {
        'baseline_ns': statistics.median(pair['baseline'] for pair in pairs),
        'candidate_ns': statistics.median(pair['candidate'] for pair in pairs),
        'median_ratio': statistics.median(ratios),
        'candidate_wins': sum(ratio < 1 for ratio in ratios),
    }
    print(f"plugin-exchange: {summary['baseline_ns']:.0f} ns -> {summary['candidate_ns']:.0f} ns, "
          f"{(summary['median_ratio'] - 1) * 100:+.1f} %, {summary['candidate_wins']}/{len(pairs)} wins", flush=True)

    if arguments.output:
        arguments.output.write_text(json.dumps({'summary': summary, 'pairs': pairs}, indent=2) + '\n')


if __name__ == '__main__':
    main()
