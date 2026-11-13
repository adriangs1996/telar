#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from check_machines_launch import outcomes


def summary(case):
    return {key: case[key] for key in ('name', 'status', 'stdout', 'stderr')} | {
        'files_sha256': hashlib.sha256(json.dumps(case['files'], sort_keys=True).encode()).hexdigest()}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--telar', type=Path, required=True)
    args = parser.parse_args()
    expected = json.loads(Path(__file__).with_name('machines_launch_expected.json').read_text())
    actual = list(map(summary, outcomes(args.telar.resolve())))
    assert len(actual) == len(expected), (len(actual), len(expected))
    failures = []
    for reference, observed in zip(expected, actual):
        if reference != observed:
            failures.append({'expected': reference, 'actual': observed})
    assert not failures, json.dumps(failures, indent=2)
    print(f'{len(actual)} machine, installation and startup contracts passed')


if __name__ == '__main__':
    main()
