#!/usr/bin/env python3
"""Summarize DOD observations without interpreting samples as function calls."""
import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path
import statistics
from echo_latency import percentile


def digest(path):
    checksum = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024*1024), b''):
            checksum.update(block)
    return checksum.hexdigest()


def rows(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def distribution(values):
    values = sorted(values)
    return dict(n=len(values), median=statistics.median(values), minimum=values[0], maximum=values[-1],
                p95=percentile(values, .95), p99=percentile(values, .99)) if values else dict(n=0)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('results', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    values = defaultdict(lambda: defaultdict(list))
    workloads = []
    layouts = []
    failures = []
    for receipt in args.results.rglob('receipt.json'):
        row = json.loads(receipt.read_text())
        if row['status'] != 0:
            failures.append(dict(file=str(receipt.relative_to(args.results)), **row))
    for path in sorted((args.results/'kernels').glob('B*-*/stdout')):
        label, kind, repetition = path.parent.name.split('-')
        for row in rows(path):
            if row['type'] in ('workload', 'benchmark'):
                row.update(build=label, repetition=int(repetition), kind=kind)
                workloads.append(row)
                value = row['median_ns_per_op'] if kind == 'bench' else row['elapsed_ns']/row['iterations']
                values[row['name']][label].append(value)
            elif row['type'] == 'layout' and label == 'B0' and repetition == '0':
                layouts.append(row)
    comparison = []
    for name, builds in values.items():
        entry = dict(name=name, unit='ns/op or ns/fixed iteration', builds={label: distribution(samples) for label, samples in builds.items()})
        if all(label in builds for label in ('B0','B2')):
            ratios = [(b/a-1)*100 for a,b in zip(builds['B0'],builds['B2']) if a]
            entry['paired_overhead_percent'] = distribution(ratios)
        comparison.append(entry)
    profiles = []
    catalog = {}
    for path in sorted(args.results.rglob('*.profile.jsonl')):
        content = rows(path)
        header = content[0]
        if header['dropped_threads'] or any(row.get('overflow') for row in content):
            failures.append(dict(file=str(path.relative_to(args.results)), error='profile capacity or overflow'))
        counts = defaultdict(int)
        histograms = []
        for row in content[1:]:
            if row['type'] == 'count':
                counts[row['metric']] += row['value']
                catalog[row['metric']] = {key: row[key] for key in ('unit','source','coverage')}
            else:
                if sum(row['buckets']) != row['count']:
                    raise ValueError(f'inconsistent histogram: {path}')
                histograms.append(row)
        profiles.append(dict(file=str(path.relative_to(args.results)), header=header,
                             counts=dict(counts), histograms=histograms))
    native_path = args.results/'native/native-runs.json'
    native = json.loads(native_path.read_text()) if native_path.exists() else []
    for section in ('scaling', 'load'):
        path = args.results/section/'native-runs.json'
        if path.exists():
            native += json.loads(path.read_text())
    latency = {}
    for label in ('B0','B2'):
        accepted = [row for row in native if row.get('build')==label and 'repetition' in row
                    and 'gpu_ms' in row and not row.get('error') and not row.get('failed')]
        samples = [sample for row in accepted for sample in row['gpu_ms'][row['warmup']:]]
        latency[label] = dict(gpu_ms=distribution(samples), runs=len(accepted),
                              run_p50_ms=[statistics.median(row['gpu_ms'][row['warmup']:]) for row in accepted],
                              viewports=[row['viewport'] for row in accepted], pty_cells=[row['pty_cells'] for row in accepted])
    fixture_results = defaultdict(set)
    for row in workloads:
        if row['kind'] == 'cpu':
            fixture_results[row['name']].add((row['iterations'], row['checksum']))
    for name, outcomes in fixture_results.items():
        if len(outcomes) != 1:
            failures.append(dict(workload=name,error='B0/B2 completed different fixed work', outcomes=sorted(outcomes)))
    result = dict(comparison=comparison, latency=latency, failures=failures,
                  native_failures=[row for row in native if row.get('error')],
                  limitations=['Counters cover the declared catalog only.',
                               'CPU workloads exclude window composition, GPU, foreign allocator internals and physical display.',
                               'Histogram buckets bound quantiles; CPU samples are not calls.',
                               'Do not combine CPU kernels, runtime DSR and native GPU latency into one ranking.'])
    for name, value in [('summary',result),('workloads',workloads),('layout',layouts),('profiles',profiles),('catalog',catalog)]:
        (args.output/f'{name}.json').write_text(json.dumps(value,indent=2)+'\n')
    evidence = {str(path.relative_to(args.results)):dict(bytes=path.stat().st_size,sha256=digest(path))
                for path in args.results.rglob('*') if path.is_file()}
    (args.output/'evidence.json').write_text(json.dumps(dict(root=str(args.results.resolve()), files=evidence),indent=2)+'\n')
    print(json.dumps(dict(workloads=len(workloads),profiles=len(profiles),failures=len(failures),latency=latency),indent=2))


if __name__ == '__main__':
    main()
