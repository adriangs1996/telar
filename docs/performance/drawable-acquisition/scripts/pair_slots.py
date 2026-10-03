#!/usr/bin/env python3
"""Alternate two builds through the existing bounded acquisition trace.

Usage: pair_slots.py A_BIN B_BIN OUT_DIR PAIRS
This diagnostic is separate from pixel-verified input latency measurements.
"""
import json
from pathlib import Path
import statistics
import subprocess
import sys


def main():
    a, b, out = [Path(arg).resolve() for arg in sys.argv[1:4]]
    pairs = int(sys.argv[4])
    out.mkdir(parents=True, exist_ok=False)
    probe = Path(__file__).resolve().parents[4] / 'tools' / 'gui_slot_probe.py'
    rows = []
    for pair in range(pairs):
        order = [('A', a), ('B', b)] if pair % 2 == 0 else [('B', b), ('A', a)]
        for label, binary in order:
            directory = out / f'p{pair}-{label}'
            with (out / f'p{pair}-{label}.log').open('w') as log:
                subprocess.run([sys.executable, str(probe), str(binary), str(directory),
                                '--workload', 'full', '--rate', '120', '--seconds', '16',
                                '--viewport', '1900', '1100'], stdout=log, stderr=log, check=True)
            report = json.loads((directory / 'analysis.json').read_text())
            summary = report['workload_window']['summary']
            if summary['failed_gpu'] or summary['failed_complete']:
                raise RuntimeError(f'failed presentation: {directory}')
            row = dict(pair=pair, build=label, summary=summary, manifest=report['manifest'])
            rows.append(row)
            (out / 'runs.json').write_text(json.dumps(rows, indent=2) + '\n')
            print(json.dumps(dict(pair=pair, build=label,
                                  drawable=summary['metrics']['drawable_ms'],
                                  cpu=summary['metrics']['drawable_cpu_ms'],
                                  fps=summary['active_fps'])), flush=True)
    table = []
    for metric in ('drawable_ms', 'drawable_cpu_ms'):
        for percentile in ('p50_ms', 'p95_ms', 'p99_ms'):
            by = {label: [r['summary']['metrics'][metric][percentile]
                          for r in rows if r['build'] == label] for label in 'AB'}
            ratios = [bb / aa - 1 for aa, bb in zip(by['A'], by['B'])]
            table.append(dict(metric=metric, percentile=percentile,
                              A=statistics.median(by['A']), B=statistics.median(by['B']),
                              paired_percent=100 * statistics.median(ratios),
                              wins=sum(r < 0 for r in ratios), pairs=pairs))
    (out / 'summary.json').write_text(json.dumps(table, indent=2) + '\n')
    print(json.dumps(table, indent=2))


if __name__ == '__main__':
    main()
