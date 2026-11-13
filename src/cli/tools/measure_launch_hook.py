#!/usr/bin/env python3
"""Measure paired hook startup before and after cold CLI family additions."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import tempfile
from check_hook_cli import run_case
from check_machines_launch import environment


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--before', type=Path, required=True)
    parser.add_argument('--after', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    binaries = {key: getattr(args, key).resolve() for key in ('before', 'after')}
    with tempfile.TemporaryDirectory(prefix='telar-launch-hook-', dir='/tmp') as temporary:
        root = Path(temporary).resolve()
        private = environment(root)
        os.environ.clear()
        os.environ.update(private)
        fixture = {'provider': 'claude', 'input': {'hook_event_name': 'SessionStart', 'session_title': 'Fixture', 'cwd': str(root)}}
        samples = {'before': [], 'after': []}
        reference = None
        for key in binaries:
            for _ in range(3):
                run_case(binaries[key], root, fixture)
        for pair in range(5):
            for key in ('before', 'after') if pair % 2 == 0 else ('after', 'before'):
                for _ in range(10):
                    result, elapsed = run_case(binaries[key], root, fixture)
                    assert result['status'] == 0 and result['frames'], result
                    if reference is None:
                        reference = result
                    assert result == reference
                    samples[key].append(elapsed)
    report = {'scope': 'Same SessionStart stdin event and acknowledging socket fixture; alternating batches under one environment.',
              'binaries': {key: {'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()} for key, path in binaries.items()},
              'samples_ns': samples, 'p50_ms': {key: statistics.median(values) / 1e6 for key, values in samples.items()}}
    report['ratio'] = report['p50_ms']['after'] / report['p50_ms']['before']
    args.output.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({key: report[key] for key in ('p50_ms', 'ratio')}))


if __name__ == '__main__':
    main()
