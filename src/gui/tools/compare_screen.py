"""Compare preencoded Screen workloads; this is not a native latency benchmark."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import statistics
import subprocess


ITERATIONS = {
    'delta-empty': 10_000_000,
    'delta-one': 3_000_000,
    'delta-row': 200_000,
    'delta-full': 10_000,
    'snapshot-full': 10_000,
    'snapshot-retained': 10_000,
}
MAXIMUM_CELLS = 130359
MAXIMUM_DIMENSION = 65535
MAXIMUM_ITERATIONS = 10_000_000
MAXIMUM_PAIRS = 31


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_run(binary, output, label, expected):
    command = [str(binary)]
    for name, value in expected.items():
        command += ['--' + name, str(value)]
    result = subprocess.run(command, capture_output=True, text=True, timeout=120)
    (output / (label + '.jsonl')).write_text(result.stdout)
    (output / (label + '.stderr')).write_text(result.stderr)
    result.check_returncode()
    row = json.loads(result.stdout)
    if any(row.get(name) != value for name, value in expected.items()):
        raise ValueError(f'Inconsistent screen workload: {row}')
    elapsed = row.get('elapsed_ns')
    if not isinstance(elapsed, (int, float)) or not math.isfinite(elapsed) or elapsed <= 0:
        raise ValueError('Expected a finite positive screen duration')
    for name in ('screen_live_bytes', 'screen_peak_bytes', 'screen_allocations', 'cell_bytes'):
        if type(row.get(name)) is not int or row[name] <= 0:
            raise ValueError(f'Invalid screen allocation counter: {name}')
    if row['screen_peak_bytes'] < row['screen_live_bytes']:
        raise ValueError('Peak screen allocation must cover live allocation')
    return row


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('baseline', type=Path)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--cases', nargs='+', choices=list(ITERATIONS), default=list(ITERATIONS))
    parser.add_argument('--pairs', type=int, default=7)
    parser.add_argument('--columns', type=int, default=82)
    parser.add_argument('--rows', type=int, default=21)
    parser.add_argument('--iterations', type=int, help='Override case-specific counts; warmup is half this count')
    options = parser.parse_args()
    if (not 1 <= options.pairs <= MAXIMUM_PAIRS or not 1 <= options.columns <= MAXIMUM_DIMENSION
            or not 1 <= options.rows <= MAXIMUM_DIMENSION or options.columns * options.rows > MAXIMUM_CELLS
            or (options.iterations is not None and not 1 <= options.iterations <= MAXIMUM_ITERATIONS)
            or len(set(options.cases)) != len(options.cases)):
        parser.error('Invalid pair count, grid size or iteration count')
    output = options.directory.resolve()
    output.mkdir(parents=True, exist_ok=False)
    binaries = {'baseline': options.baseline.resolve(), 'candidate': options.candidate.resolve()}
    identities = {name: dict(path=str(path), sha256=digest(path)) for name, path in binaries.items()}
    manifest = dict(binaries=identities, command_line=os.sys.argv,
                    uptime=subprocess.check_output(['uptime'], text=True).strip(),
                    scope='Preencoded-frame descriptor selection and Screen application, excluding encoding. Allocation counters cover Screen-owned storage, not process RSS or fixture storage. No GUI, runtime or native presentation timing.')
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    summary = {}
    for case in options.cases:
        iterations = options.iterations or ITERATIONS[case]
        expected = dict(case=case, iterations=iterations, warmup=iterations // 2,
                        columns=options.columns, rows=options.rows)
        pairs = []
        for index in range(options.pairs):
            order = ['baseline', 'candidate'] if index % 2 == 0 else ['candidate', 'baseline']
            pair = {name: read_run(binaries[name], output, f'{case}-{index}-{name}', expected)
                    for name in order}
            pairs.append(pair)
            (output / (case + '-pairs.json')).write_text(json.dumps(pairs, indent=2) + '\n')
        before = [pair['baseline']['elapsed_ns'] / iterations for pair in pairs]
        after = [pair['candidate']['elapsed_ns'] / iterations for pair in pairs]
        summary[case] = dict(baseline_median_ns=statistics.median(before),
                             candidate_median_ns=statistics.median(after),
                             wins=sum(right < left for left, right in zip(before, after)),
                             pairs=len(pairs), allocation_counters={name: {
                                 field: pairs[-1][name][field] for field in
                                 ('screen_live_bytes', 'screen_peak_bytes', 'screen_allocations', 'cell_bytes')}
                                 for name in binaries})
        (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
        print(case, json.dumps(summary[case]), flush=True)
    if any(digest(path) != identities[name]['sha256'] for name, path in binaries.items()):
        raise ValueError('A screen probe binary changed during comparison')


if __name__ == '__main__':
    main()
