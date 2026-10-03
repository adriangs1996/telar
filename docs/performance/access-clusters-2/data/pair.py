#!/usr/bin/env python3
"""Alternate two frozen builds, preserving raw workload records and pair ratios."""
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys

baseline, candidate, kind, pair_count, pattern_text, destination = sys.argv[1:]
patterns = pattern_text.split(',')
output = Path(destination)
output.mkdir(parents=True, exist_ok=False)
records = []
for pair in range(int(pair_count)):
    for pattern in patterns:
        for side in (['A', 'B'] if pair % 2 == 0 else ['B', 'A']):
            prefix = baseline if side == 'A' else candidate
            env = dict(os.environ)
            if kind == 'probe':
                command = [str(Path(prefix) / 'bin/telar-dod-probe')]
                env.update(DOD_TERMINAL_ONLY='1', DOD_MODE=pattern,
                           DOD_SAMPLES='1000' if pattern == 'full' else ('8' if pattern == 'font' else '3000'),
                           DOD_WARMUP='2' if pattern == 'font' else '300')
            elif kind == 'allprobe':
                command = [str(Path(prefix) / 'bin/telar-dod-probe')]
                env.update(DOD_SAMPLES='64', DOD_WARMUP='4')
            elif kind == 'chrome':
                command = [str(Path(prefix) / 'bin/telar-dod-probe')]
                env.update(DOD_CHROME_ONLY='1', DOD_SAMPLES='1000', DOD_WARMUP='200')
            else:
                command = [str(Path(prefix) / 'bin/telar-benchmarks'), '--samples', '12', '--json', '--filter', pattern]
            result = subprocess.run(command, env=env, capture_output=True, text=True, check=True)
            (output / f'{pair}-{pattern or "all"}-{side}.jsonl').write_text(result.stdout)
            if result.stderr:
                (output / f'{pair}-{pattern or "all"}-{side}.stderr').write_text(result.stderr)
            for line in result.stdout.splitlines():
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if row.get('type') not in ['workload', 'benchmark']:
                    continue
                value = row['elapsed_ns'] / row['iterations'] if kind in ['probe', 'chrome', 'allprobe'] else row['median_ns_per_op']
                records.append(dict(pair=pair, side=side, name=row['name'], ns_per_op=value, raw=row))
    print(f'pair {pair + 1}/{pair_count}', flush=True)
(output / 'runs.json').write_text(json.dumps(records, indent=2) + '\n')
summary = []
for name in sorted({row['name'] for row in records}):
    by_side = {side: sorted([r for r in records if r['name'] == name and r['side'] == side], key=lambda x:x['pair']) for side in ['A','B']}
    a, b = by_side['A'], by_side['B']
    assert len(a) == len(b) == int(pair_count)
    if any(r['ns_per_op'] == 0 for r in a):
        print(f'{name}: zero baseline; ratio not meaningful', flush=True)
        continue
    ratios = [y['ns_per_op'] / x['ns_per_op'] - 1 for x,y in zip(a,b)]
    row = dict(name=name, baseline_ns=statistics.median(r['ns_per_op'] for r in a),
               candidate_ns=statistics.median(r['ns_per_op'] for r in b),
               paired_percent=statistics.median(ratios)*100, wins=sum(r<0 for r in ratios), losses=sum(r>0 for r in ratios), ties=sum(r==0 for r in ratios), pairs=len(ratios),
               paired_percent_min=min(ratios)*100, paired_percent_max=max(ratios)*100)
    for key in ['p50_ns', 'p95_ns', 'p99_ns', 'shape_calls', 'raster_attempts', 'shaping_cache_bytes', 'p95_ns_per_op', 'p99_ns_per_op', 'payload_bytes_per_op', 'allocations', 'allocated_bytes', 'live_bytes', 'live_requested_bytes', 'measured_allocations', 'last_frame_quads']:
        if all(key in r['raw'] for r in a+b):
            row[key] = {side: statistics.median(r['raw'][key] for r in by_side[side]) for side in ['A','B']}
    summary.append(row)
    print(f"{name:43} {row['baseline_ns']:10.1f} {row['candidate_ns']:10.1f} {row['paired_percent']:+7.2f}% {row['wins']}/{row['pairs']}",flush=True)
(output/'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
