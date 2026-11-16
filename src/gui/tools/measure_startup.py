"""Measure how long the GUI takes to start, with builds of gui-startup-probe.

    measure_startup.py PROBE [PROBE...] [--rounds N] [--warmup N] [--output FILE]

Each round runs every probe once, in an order that rotates from round to round, so a
slow stretch of the machine falls on every probe alike. The first probe is the baseline:
every other one is compared with it round by round. Times count from just before the
process is spawned, so they include the dynamic loader and the static initializers that
register QML types, which run before main.

Milestones, in milliseconds from the spawn:
- main: main is entered.
- root: Main.qml's window exists (QQmlApplicationEngine::loadFromModule returned).
- frame: the window presented its first frame.
qml is root minus the instant the controller was ready: the QML load alone.

For each one it reports the median, the quartiles and a distribution-free 95% confidence
interval of the median; for a comparison, the median of the per-round differences with
its interval, and in how many rounds the probe was faster. An interval that contains
zero means the rounds cannot tell the builds apart.

Run the probes from a directory without a Telar/ folder, as an installed GUI is: the QML
engine also looks for modules beside the executable, and a build tree has them there.
"""
import argparse
import json
import math
import os
from pathlib import Path
import platform
import statistics
import subprocess
import sys
import time

MILESTONES = ('main', 'root', 'frame', 'qml')
CONFIDENCE = 0.95


def run(executable):
    """One start of the probe: milliseconds of each milestone and peak resident MiB."""
    spawned = time.time_ns()
    process = subprocess.Popen([str(executable)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    output = process.stdout.read()
    process.stdout.close()
    _, status, usage = os.wait4(process.pid, 0)
    process.returncode = os.waitstatus_to_exitcode(status)
    if process.returncode != 0:
        raise RuntimeError(f'{executable} failed with {process.returncode}:\n{output}')

    lines = [line for line in output.splitlines() if line.startswith('{')]
    if not lines:
        raise RuntimeError(f'{executable} printed no result:\n{output}')

    instants = json.loads(lines[-1])
    milliseconds = {name: (instants[name + '_ns'] - spawned) / 1e6 for name in ('main', 'root', 'frame')}
    milliseconds['qml'] = (instants['root_ns'] - instants['controller_ns']) / 1e6
    # ru_maxrss is in bytes on macOS and in KiB on Linux.
    scale = 1 if platform.system() == 'Darwin' else 1024
    milliseconds['peak_rss_mib'] = usage.ru_maxrss * scale / (1 << 20)
    return milliseconds


def median_interval(values):
    """The order statistics that bound the median with CONFIDENCE, without assuming a distribution."""
    ordered = sorted(values)
    count = len(ordered)
    tail = (1 - CONFIDENCE) / 2
    rank = 0
    cumulative = 0.0
    while rank < count:
        cumulative += math.comb(count, rank) / 2 ** count
        if cumulative > tail:
            break
        rank += 1

    if rank == 0:
        return None

    return [round(ordered[rank - 1], 2), round(ordered[count - rank], 2)]


def summary(values):
    quartiles = statistics.quantiles(values, n=4) if len(values) > 1 else [values[0]] * 3
    return {
        'median': round(statistics.median(values), 2),
        'quartiles': [round(quartiles[0], 2), round(quartiles[2], 2)],
        'median_interval': median_interval(values),
        'minimum': round(min(values), 2),
        'maximum': round(max(values), 2),
    }


def measure(probes, rounds, warmup):
    for _ in range(warmup):
        for probe in probes:
            run(probe)

    samples = [[] for _ in probes]
    for index in range(rounds):
        for offset in range(len(probes)):
            position = (index + offset) % len(probes)
            samples[position].append(run(probes[position]))

    fields = (*MILESTONES, 'peak_rss_mib')
    result = {
        'machine': f'{platform.system()} {platform.release()} {platform.machine()}, {os.cpu_count()} CPUs',
        'rounds': rounds,
        'warmup_rounds': warmup,
        'confidence': CONFIDENCE,
        'probes': [],
    }
    for probe, runs in zip(probes, samples):
        entry = {'probe': str(probe), 'size_bytes': probe.stat().st_size}
        entry.update({field: summary([sample[field] for sample in runs]) for field in fields})
        if probe != probes[0]:
            entry['against_first'] = {}
            for field in fields:
                differences = [sample[field] - first[field] for sample, first in zip(runs, samples[0])]
                baseline = statistics.median(first[field] for first in samples[0])
                median = statistics.median(differences)
                entry['against_first'][field] = {
                    'median_difference': round(median, 2),
                    'median_difference_percent': round(100 * median / baseline, 1) if baseline else None,
                    'median_interval': median_interval(differences),
                    'faster_rounds': sum(difference < 0 for difference in differences),
                }

        result['probes'].append(entry)

    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('probes', nargs='+', type=Path)
    parser.add_argument('--rounds', type=int, default=40)
    parser.add_argument('--warmup', type=int, default=3)
    parser.add_argument('--output', type=Path)
    options = parser.parse_args()
    if options.rounds < 1 or options.warmup < 0:
        parser.error('--rounds must be positive and --warmup not negative')

    probes = [probe.resolve() for probe in options.probes]
    for probe in probes:
        if not os.access(probe, os.X_OK):
            parser.error(f'{probe} is not an executable')
        if (probe.parent / 'Telar').exists():
            print(f'warning: {probe.parent} holds a Telar/ folder of QML modules', file=sys.stderr)

    rendered = json.dumps(measure(probes, options.rounds, options.warmup), indent=2) + '\n'
    if options.output is not None:
        options.output.write_text(rendered)

    print(rendered, end='')


if __name__ == '__main__':
    main()
