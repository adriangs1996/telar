#!/usr/bin/env python3
"""Flat self-sampling of private benchmark processes; never a timing comparison."""
import argparse
import bisect
import collections
import hashlib
import json
from pathlib import Path
import re
import subprocess

from bench_control_queries import WORKLOADS


def summarize(raw, library, nm):
    target = next(image for image in raw['images'] if Path(image['name']).resolve() == library.resolve())
    output = subprocess.check_output([nm, '-n', '--defined-only', str(library)], text=True)
    symbols = []
    for line in output.splitlines():
        match = re.fullmatch(r'([0-9a-fA-F]+)\s+[tT]\s+(.+)', line)
        if match:
            symbols.append((int(match[1], 16), match[2]))
    addresses = [entry[0] for entry in symbols]
    functions = collections.Counter()
    modules = collections.Counter()
    for pc in raw['pcs']:
        if not pc:
            modules['unpublished_sample'] += 1
        elif target['text_begin'] <= pc < target['text_end']:
            index = bisect.bisect_right(addresses, pc - target['slide']) - 1
            functions[symbols[index][1] if index >= 0 else 'unknown_target_function'] += 1
            modules[str(library)] += 1
        else:
            image = next((item for item in raw['images'] if item['text_begin'] <= pc < item['text_end']), None)
            modules[image['name'] if image else 'unknown_image'] += 1
    count = len(raw['pcs'])
    if count < 100:
        raise RuntimeError('Insufficient delivered profiling samples')
    return {'samples': count, 'modules': dict(modules.most_common()),
            'functions': [{'name': name, 'samples': hits, 'fraction_of_all_samples': hits / count}
                          for name, hits in functions.most_common()],
            'scope': 'Flat sampled PCs; function ranges from sorted text symbols, no call-stack or inlined-source attribution. Includes fixture setup/destruction and any own background threads.'}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--driver', type=Path, required=True)
    parser.add_argument('--nm', default='llvm-nm', help='LLVM symbol reader executable')
    parser.add_argument('--native', type=Path, required=True)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--case', action='append', choices=[name for name, (_, _, fragment) in WORKLOADS.items() if fragment == 0])
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=False)
    report = {'scope': 'Diagnostic self-profiling only, not relative timing or acceptance.', 'results': {},
              'hashes': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in [args.driver, args.native, args.reference, Path(__file__)]}}
    for name in args.case or ['ordinary', 'ordinary-styled', 'mixed', 'graphics-payload']:
        data, _, fragment = WORKLOADS[name]
        if fragment:
            raise RuntimeError('The self-profiler requires whole input slices')
        payload = args.output_dir / (name + '.input')
        payload.write_bytes(data)
        suffix = {'checksum-ascii-screen': '_checksum_ascii', 'checksum-styled-screen': '_checksum_styled',
                  'checksum-grapheme-screen': '_checksum_graphemes'}.get(name, '_checksum' if name.startswith('checksum-') else '')
        result = {'input_sha256': hashlib.sha256(data).hexdigest(), 'variants': {}}
        report['results'][name] = result
        for label, library, symbol in [('native', args.native, 'query_probe_benchmark_component'),
                                        ('application', args.reference, 'query_probe_benchmark')]:
            command = [str(args.driver.resolve()), str(library.resolve()), symbol + suffix, str(payload.resolve())]
            raw_path = args.output_dir / f'{name}-{label}-raw.json'
            with raw_path.open('w') as output:
                run = subprocess.run(command, stdout=output, stderr=subprocess.PIPE, text=True, timeout=40)
            if run.returncode:
                raise RuntimeError(f'Owned profiler failed: {command}: {run.returncode}: {run.stderr}')
            raw = json.loads(raw_path.read_text())
            result['variants'][label] = {'command': command, 'stderr': run.stderr,
                                         'raw_sha256': hashlib.sha256(raw_path.read_bytes()).hexdigest(),
                                         **summarize(raw, library, args.nm)}
            print(name, label, result['variants'][label]['samples'], flush=True)
        (args.output_dir / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
