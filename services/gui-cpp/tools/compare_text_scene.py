import argparse
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import re
import statistics
import subprocess


OPERATIONS = ('create', 'rebuild', 'repaint')
GLYPH_COUNTS = (32, 128, 512)


def index_run(output, options):
    rows = [json.loads(line) for line in output.splitlines()]
    indexed = {(row['operation'], row['glyphs']): row for row in rows}
    expected = {(operation, glyphs) for operation in OPERATIONS for glyphs in GLYPH_COUNTS}
    if len(rows) != len(expected) or set(indexed) != expected:
        raise ValueError('Expected all nine unique text scene cases')

    for row in rows:
        counts_match = row['iterations'] == options.iterations and row['warmup'] == options.warmup
        if not counts_match or not math.isfinite(row['elapsed_ns']) or row['elapsed_ns'] <= 0:
            raise ValueError('The scene measurement has inconsistent counts or timing')

        digest = row.get('scene_sha256')
        if not isinstance(digest, str) or re.fullmatch('[0-9a-f]{64}', digest) is None:
            raise ValueError('The scene measurement has no valid geometry digest')

    return indexed


def read_run(binary, options, directory, label):
    command = [str(binary), '--iterations', str(options.iterations), '--warmup', str(options.warmup)]
    environment = dict(os.environ, QSG_INFO='1')
    try:
        result = subprocess.run(command, capture_output=True, text=True, env=environment, check=False, timeout=options.timeout_seconds)
    except subprocess.TimeoutExpired as failure:
        for suffix, output in (('jsonl', failure.stdout), ('stderr', failure.stderr)):
            text = output.decode(errors='replace') if isinstance(output, bytes) else output or ''
            (directory / (label + '.' + suffix)).write_text(text)
        raise

    (directory / (label + '.jsonl')).write_text(result.stdout)
    (directory / (label + '.stderr')).write_text(result.stderr)
    result.check_returncode()

    return index_run(result.stdout, options)


def summarize(pairs):
    cases = []
    for operation, glyphs in sorted(pairs[0]['baseline']):
        before = [pair['baseline'][operation, glyphs]['elapsed_ns'] / pair['baseline'][operation, glyphs]['iterations'] for pair in pairs]
        after = [pair['candidate'][operation, glyphs]['elapsed_ns'] / pair['candidate'][operation, glyphs]['iterations'] for pair in pairs]
        wins = sum(right < left for left, right in zip(before, after))
        cases.append(dict(
            operation=operation,
            glyphs=glyphs,
            baseline_ns_per_operation=before,
            candidate_ns_per_operation=after,
            baseline_median_ns=statistics.median(before),
            candidate_median_ns=statistics.median(after),
            median_paired_ratio=statistics.median(right / left for left, right in zip(before, after)),
            wins=wins,
            pairs=len(pairs),
        ))
    return cases


def main():
    parser = argparse.ArgumentParser(description='Compare scene construction CPU cost and exact final geometry without the application controller or runtime')
    parser.add_argument('baseline', type=Path)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('--output-dir', required=True, type=Path)
    parser.add_argument('--pairs', type=int, default=7)
    parser.add_argument('--iterations', type=int, default=2000)
    parser.add_argument('--warmup', type=int, default=100)
    parser.add_argument('--timeout-seconds', type=float, default=120)
    options = parser.parse_args()
    if not 1 <= options.pairs <= 31 or not 1 <= options.iterations <= 1_000_000 or not 0 <= options.warmup <= 1_000_000:
        parser.error('Expected 1..31 pairs, 1..1000000 iterations and 0..1000000 warmup operations')
    if not math.isfinite(options.timeout_seconds) or options.timeout_seconds <= 0:
        parser.error('Expected a finite positive timeout')
    directory = options.output_dir.resolve()
    directory.mkdir(parents=True, exist_ok=False)
    binaries = dict(baseline=options.baseline.resolve(), candidate=options.candidate.resolve())
    manifest = dict(
        recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        binaries={name: dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest()) for name, path in binaries.items()},
        command_line=os.sys.argv,
        environment={name: value for name, value in os.environ.items() if name.startswith(('QT_', 'QSG_'))},
        options=dict(pairs=options.pairs, iterations=options.iterations, warmup=options.warmup, timeout_seconds=options.timeout_seconds),
        uptime=subprocess.check_output(['uptime'], text=True).strip(),
    )
    (directory / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    pairs = []
    expected = None
    for index in range(options.pairs):
        order = ['baseline', 'candidate'] if index % 2 == 0 else ['candidate', 'baseline']
        pair = {}
        for name in order:
            rows = read_run(binaries[name], options, directory, f'{index}-{name}')
            identities = {key: row['scene_sha256'] for key, row in rows.items()}
            if expected is None:
                expected = identities
            if identities != expected:
                raise ValueError(f'Scene geometry or material values differ in pair {index}: {name}')
            pair[name] = rows
        pairs.append(pair)
        print('Completed pair', index + 1, flush=True)

    for name, path in binaries.items():
        if hashlib.sha256(path.read_bytes()).hexdigest() != manifest['binaries'][name]['sha256']:
            raise ValueError(f'The {name} binary changed during measurement')

    cases = summarize(pairs)
    result = dict(
        manifest=manifest,
        cases=cases,
        geometry_sha256=[dict(operation=operation, glyphs=glyphs, sha256=digest) for (operation, glyphs), digest in sorted(expected.items())],
        scope='Native Qt CPU scene-node construction, rebuilding and repainting with warm glyph/texture caches. The final ordered vertex values, matrices, material colors and blend modes match exactly in every run. This does not measure GPU drawing, complete-frame latency, process memory or asynchronous upload completion.',
    )
    (directory / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    for case in cases:
        print(f"{case['operation']}/{case['glyphs']}: {case['baseline_median_ns']:.1f} -> {case['candidate_median_ns']:.1f} ns/op; wins {case['wins']}/{case['pairs']}")


if __name__ == '__main__':
    main()
