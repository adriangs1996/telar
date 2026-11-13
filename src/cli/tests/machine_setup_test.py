#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from check_machine_setup import run, scenarios
from machines_launch_test import summary


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--telar', type=Path, required=True)
    args = parser.parse_args()
    actual = []
    cases = [(f'{index}-{provider}', provider, seed, False) for index, (provider, seed) in enumerate(scenarios())]
    cases += [('login-'+mode, 'claude', '{}', mode) for mode in ('done', 'pending', 'ended', 'failed', 'lost', 'ssh-failure')]
    for name, provider, seed, login in cases:
        for index, result in enumerate(run(args.telar.resolve(), provider, seed, login)):
            actual.append(summary({'name': f'{name}-{index}', **result}))
    expected = json.loads(Path(__file__).with_name('machine_setup_expected.json').read_text())
    assert len(actual) == len(expected)
    failures = [{'expected': reference, 'actual': observed} for reference, observed in zip(expected, actual) if reference != observed]
    assert not failures, json.dumps(failures, indent=2)
    print(f'{len(actual)} setup, configuration and login contracts passed')


if __name__ == '__main__':
    main()
