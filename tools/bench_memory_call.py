#!/usr/bin/env python3
"""Alloc+free through Memory against the Allocator concept, across build variants.

Each variant is a Release build of lib/base with the `base-probes` target. A pair
runs every variant once, in forward order on even pairs and reversed on odd ones,
and each run executes memory-call-probe-single and memory-call-probe. A probe run
already alternates the concept and the Memory loop inside one process.

    tools/bench_memory_call.py --variant thin=out/thin --variant wpv=out/wpv
"""
import argparse
import json
from pathlib import Path
import statistics
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from benchmark_host import HostLoadGate

PROBES = ('memory-call-probe-single', 'memory-call-probe')
CASES = ('pair', 'batch', 'vector')


def variant(text):
    label, separator, directory = text.partition('=')
    if not separator or not label:
        raise argparse.ArgumentTypeError('expected LABEL=BUILD_DIRECTORY')
    for probe in PROBES:
        if not (Path(directory) / probe).is_file():
            raise argparse.ArgumentTypeError(f'{directory} has no {probe}; build the base-probes target')
    return label, Path(directory)


def run(directory, probe, rounds, implementation):
    output = subprocess.check_output([str(directory / probe), str(rounds), str(implementation)], text=True, timeout=600)
    return json.loads(output)['cases']


def summarize(samples, labels):
    baseline = labels[0]
    summary = {}
    for label in labels:
        summary[label] = {}
        for probe in PROBES:
            summary[label][probe] = {}
            for case in CASES:
                runs = [sample[label][probe][case] for sample in samples]
                base_runs = [sample[baseline][probe][case] for sample in samples]
                summary[label][probe][case] = {
                    'concept_ns': statistics.median(run['concept_ns'] for run in runs),
                    'memory_ns': statistics.median(run['memory_ns'] for run in runs),
                    'delta_ns': statistics.median(run['delta_ns'] for run in runs),
                    'memory_slower_rounds': sum(run['memory_slower'] for run in runs),
                    'memory_faster_than_baseline': sum(run['memory_ns'] < base['memory_ns'] for run, base in zip(runs, base_runs)),
                }
    return summary


def table(summary, labels, pairs, rounds):
    lines = [f'| Variante | Probe | Caso | Concept (ns) | Memory (ns) | Diferencia (ns) | Rondas con Memory más lenta | Memory más rápida que {labels[0]} |',
             '| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |']
    for label in labels:
        for probe in PROBES:
            for case in CASES:
                entry = summary[label][probe][case]
                lines.append(f"| {label} | {probe.removeprefix('memory-call-probe').lstrip('-') or 'several'} | {case} | "
                             f"{entry['concept_ns']:.2f} | {entry['memory_ns']:.2f} | {entry['delta_ns']:+.2f} | "
                             f"{entry['memory_slower_rounds']}/{pairs * rounds} | {entry['memory_faster_than_baseline']}/{pairs} |")
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--variant', action='append', type=variant, required=True, help='LABEL=BUILD_DIRECTORY; the first is the baseline')
    parser.add_argument('--pairs', type=int, default=7)
    parser.add_argument('--rounds', type=int, default=21, help='rounds inside each probe run')
    parser.add_argument('--implementation', type=int, default=0, help='0 system, 1 budget, 2 synchronized budget')
    parser.add_argument('--host-report', type=Path, required=True, help='where the host load gate writes its report')
    parser.add_argument('--output', type=Path, help='raw samples and summary as JSON')
    arguments = parser.parse_args()

    variants = dict(arguments.variant)
    labels = list(variants)
    if len(labels) != len(arguments.variant):
        parser.error('variant labels must be unique')

    gate = HostLoadGate(arguments.host_report)
    samples = []
    for pair in range(arguments.pairs):
        order = labels if pair % 2 == 0 else labels[::-1]
        sample = {}
        for label in order:
            with gate.run(f'pair{pair}:{label}'):
                sample[label] = {probe: run(variants[label], probe, arguments.rounds, arguments.implementation) for probe in PROBES}
        samples.append(sample)
    gate.finish()

    summary = summarize(samples, labels)
    if arguments.output:
        arguments.output.write_text(json.dumps({'labels': labels, 'implementation': arguments.implementation,
                                                'samples': samples, 'summary': summary}, indent=2) + '\n')
    print(table(summary, labels, arguments.pairs, arguments.rounds))


if __name__ == '__main__':
    main()
