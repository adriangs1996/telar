#!/usr/bin/env python3
"""Run paired local probes serially. This does not implement the Linux perf gate."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import sys


def run(command, cwd, prefix):
    with prefix.with_suffix('.stdout').open('w') as stdout, prefix.with_suffix('.stderr').open('w') as stderr:
        subprocess.run(command, cwd=cwd, stdout=stdout, stderr=stderr, check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--baseline-source', type=Path, required=True)
    parser.add_argument('--candidate-source', type=Path, required=True)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--repetitions', type=int, default=5)
    args = parser.parse_args()
    args.output.mkdir(parents=True)
    metadata = dict(platform=platform.platform(), machine=platform.machine(),
                    zig=subprocess.check_output(['zig', 'version'], text=True).strip(),
                    repetitions=args.repetitions, samples=20, sample_ms=40,
                    binary_sha256={label: hashlib.sha256(binary.read_bytes()).hexdigest()
                                   for label, binary in [('baseline', args.baseline), ('candidate', args.candidate)]})
    (args.output / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
    versions = [('baseline', args.baseline_source), ('candidate', args.candidate_source)]
    for repetition in range(args.repetitions):
        for label, source in versions[::1 if repetition % 2 == 0 else -1]:
            print(f'{repetition + 1}/{args.repetitions} {label}', flush=True)
            stem = f'{label}-{repetition}'
            run(['zig', 'build', 'bench', '--', '--samples', '20', '--sample-ms', '40', '--json'],
                source, args.output / (stem + '-bench'))
            for step in ('test-isolation', 'test-compression-isolation'):
                run(['zig', 'build', step, '-Doptimize=ReleaseFast'], source, args.output / (stem + '-' + step))
    run([sys.executable, 'tools/perf_e2e.py', '--baseline', str(args.baseline),
         '--candidate', str(args.candidate), '--output', str(args.output / 'e2e'),
         '--repetitions', str(args.repetitions), '--samples', '200',
         '--cases', 'echo', 'load', 'slow-host', 'graphics'],
        args.candidate_source, args.output / 'e2e-run')


if __name__ == '__main__':
    main()
