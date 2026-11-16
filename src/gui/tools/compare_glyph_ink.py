"""Paired comparison of the block, box and Braille glyph geometry of two gui-glyph-ink-probe builds.

The geometry oracle runs first: both builds must print the same rectangles for every glyph and
cell size of `--dump`, and every timed pair must report the same checksum.
"""
import argparse
import hashlib
import json
from pathlib import Path
import statistics
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'tools'))
from benchmark_host import HostLoadGate


WORKLOADS = ('block', 'quadrant', 'slab', 'box', 'braille', 'all')
MAXIMUM_ITERATIONS = 100_000_000
MAXIMUM_PAIRS = 31


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_run(binary, output, label, workload, iterations):
    command = [str(binary), '--workload', workload, '--iterations', str(iterations), '--warmup', str(max(1, iterations // 10))]
    result = subprocess.run(command, capture_output=True, text=True, timeout=300)
    (output / (label + '.json')).write_text(result.stdout)
    result.check_returncode()
    row = json.loads(result.stdout)
    if row.get('workload') != workload or row.get('iterations') != iterations:
        raise ValueError(f'Inconsistent glyph ink workload: {row}')
    elapsed = row.get('elapsed_ns')
    if not isinstance(elapsed, int) or elapsed <= 0 or not isinstance(row.get('checksum'), str):
        raise ValueError(f'Invalid glyph ink run: {row}')
    return row


def dump(binary, output, name):
    path = output / (name + '-dump.txt')
    with path.open('w') as stream:
        subprocess.run([str(binary), '--dump'], stdout=stream, check=True, timeout=300)
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('baseline', type=Path)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--workloads', nargs='+', choices=WORKLOADS, default=list(WORKLOADS))
    parser.add_argument('--pairs', type=int, default=7)
    parser.add_argument('--iterations', type=int, default=50_000)
    options = parser.parse_args()
    if (not 1 <= options.pairs <= MAXIMUM_PAIRS or not 1 <= options.iterations <= MAXIMUM_ITERATIONS
            or len(set(options.workloads)) != len(options.workloads)):
        parser.error('Invalid pair count, iteration count or workload list')
    output = options.directory.resolve()
    output.mkdir(parents=True, exist_ok=False)
    binaries = {'baseline': options.baseline.resolve(), 'candidate': options.candidate.resolve()}
    identities = {name: dict(path=str(path), sha256=digest(path)) for name, path in binaries.items()}
    manifest = dict(binaries=identities, command_line=sys.argv,
                    uptime=subprocess.check_output(['uptime'], text=True).strip(),
                    scope='Glyph geometry and ink reads of ui/scene/cell_glyphs.hpp, without Qt scene nodes or rendering.')
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    dumps = {name: digest(dump(path, output, name)) for name, path in binaries.items()}
    if dumps['baseline'] != dumps['candidate']:
        raise ValueError('The builds draw different glyph geometry; compare the two dump files')
    print('geometry oracle: identical', flush=True)
    host = HostLoadGate(output / 'host-load.json')
    host.checkpoint('before-series')
    summary = {}
    for workload in options.workloads:
        pairs = []
        for index in range(options.pairs):
            order = ['baseline', 'candidate'] if index % 2 == 0 else ['candidate', 'baseline']
            pair = {}
            for name in order:
                with host.run(f'{workload}-{index}-{name}'):
                    pair[name] = read_run(binaries[name], output, f'{workload}-{index}-{name}', workload, options.iterations)
            if pair['baseline']['checksum'] != pair['candidate']['checksum']:
                raise ValueError(f'Different glyph ink checksums for {workload}')
            pairs.append(pair)
        before = [pair['baseline']['elapsed_ns'] / options.iterations for pair in pairs]
        after = [pair['candidate']['elapsed_ns'] / options.iterations for pair in pairs]
        ratios = [right / left for left, right in zip(before, after)]
        summary[workload] = dict(baseline_median_ns=statistics.median(before), candidate_median_ns=statistics.median(after),
                                 median_ratio=statistics.median(ratios), wins=sum(right < left for left, right in zip(before, after)),
                                 pairs=len(pairs))
        (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
        result = summary[workload]
        print(f"{workload}: {result['baseline_median_ns']:.1f} -> {result['candidate_median_ns']:.1f} ns/frame; "
              f"ratio {result['median_ratio']:.4f}; wins {result['wins']}/{result['pairs']}", flush=True)
    host.finish()
    if any(digest(path) != identities[name]['sha256'] for name, path in binaries.items()):
        raise ValueError('A glyph ink probe binary changed during comparison')


if __name__ == '__main__':
    main()
