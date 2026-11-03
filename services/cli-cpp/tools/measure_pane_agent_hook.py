#!/usr/bin/env python3
"""Paired hook startup check around the pane/agent CLI port."""
import argparse
import json
from pathlib import Path
import statistics
import tempfile
from check_hook_cli import run_case


def main():
    parser = argparse.ArgumentParser()
    for name in ['before', 'after', 'scratch', 'output']:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--iterations', type=int, default=40)
    args = parser.parse_args()
    samples = {'before': [], 'after': []}
    fixture = {'provider': 'claude', 'input': {'hook_event_name': 'SessionStart', 'session_title': 'Fixture', 'cwd': '/tmp'}}
    with tempfile.TemporaryDirectory(prefix='hook-', dir=args.scratch) as directory:
        root = Path(directory)
        for index in range(args.iterations + 4):
            pair = {}
            for name in (['before', 'after'] if index % 2 == 0 else ['after', 'before']):
                value, elapsed = run_case(getattr(args, name).resolve(), root, fixture)
                assert value['status'] == 0 and value['frames'], value
                pair[name] = value
                if index >= 4:
                    samples[name].append(elapsed / 1e6)
            assert pair['before'] == pair['after']
    output = {name: {'p50_ms': statistics.median(values), 'samples_ms': values} for name, values in samples.items()}
    output['p50_ratio'] = output['after']['p50_ms'] / output['before']['p50_ms']
    args.output.write_text(json.dumps(output, indent=2) + '\n')
    print(json.dumps({name: value if name == 'p50_ratio' else value['p50_ms'] for name, value in output.items()}))


if __name__ == '__main__':
    main()
