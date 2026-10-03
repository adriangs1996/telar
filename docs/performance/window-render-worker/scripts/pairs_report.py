#!/usr/bin/env python3
"""Markdown tables and win counts from pair_load.py and pair_gui.py runs."""
import json, statistics, sys
from pathlib import Path


def pct(v, p):
    v = sorted(v); k = (len(v) - 1) * p; f = int(k); c = min(f + 1, len(v) - 1)
    return v[f] + (v[c] - v[f]) * (k - f)


def cputime_seconds(text):
    if not text:
        return None
    minutes, seconds = text.split(':')
    return int(minutes) * 60 + float(seconds)


def table(rows, cases, get, out):
    lines = ['| Case | Metric | A median ms | B median ms | paired change | B wins | A range | B range |', '| --- | --- | ---: | ---: | ---: | ---: | --- | --- |']
    verdicts = {}
    for case in cases:
        for metric in ('p50_ms', 'p95_ms', 'p99_ms'):
            by = {label: [get(r, case, metric) for r in sorted(rows, key=lambda r: r['pair']) if r['build'] == label and r.get('case', case) == case] for label in 'AB'}
            ratios = [bb / aa - 1 for aa, bb in zip(by['A'], by['B'])]
            wins = sum(r < 0 for r in ratios)
            verdicts[(case, metric)] = (wins, len(ratios))
            lines.append(f"| {case} | {metric[:-3]} | {statistics.median(by['A']):.2f} | {statistics.median(by['B']):.2f} | {statistics.median(ratios) * 100:+.1f}% | {wins}/{len(ratios)} | {min(by['A']):.2f}..{max(by['A']):.2f} | {min(by['B']):.2f}..{max(by['B']):.2f} |")
    out.append('\n'.join(lines))
    return verdicts


def usage_table(rows, out):
    lines = ['| Build | peak RSS MiB (median of runs) | CPU time s (median of runs) |', '| --- | ---: | ---: |']
    for label in 'AB':
        rss = [r['usage'].get('rss_kib', 0) / 1024 for r in rows if r['build'] == label and r.get('usage')]
        cpu = [cputime_seconds(r['usage'].get('cputime')) for r in rows if r['build'] == label and r.get('usage', {}).get('cputime')]
        lines.append(f"| {label} | {statistics.median(rss):.0f} | {statistics.median(cpu):.2f} |")
    out.append('\n'.join(lines))


def main():
    load = json.loads((Path(sys.argv[1]) / 'runs.json').read_text())
    gui = json.loads((Path(sys.argv[2]) / 'runs.json').read_text()) if len(sys.argv) > 2 and (Path(sys.argv[2]) / 'runs.json').exists() else []
    out = []
    out.append('### Four panes, three flooding (`gui_tui_latency.py --mode gui --cases single splits-load --panes 4`)\n')
    verdicts = table(load, ['single', 'splits-load'], lambda r, c, m: r[c][m], out)
    out.append('\nViewports: ' + ', '.join(sorted({f"{r['single']['viewport']}" for r in load})) + '. GUI process usage over each run (ps):\n')
    usage_table(load, out)
    if gui:
        out.append('\n### One pane (`gui_latency.py`, graphics gate configuration)\n')
        variants = sorted({r['variant'] for r in gui})
        rows = []
        for v in variants:
            vr = [dict(r, case=v) for r in gui if r['variant'] == v]
            rows += vr
        verdicts.update(table(rows, variants, lambda r, c, m: r[m], out))
        vp = sorted({tuple(r['viewport']) for r in gui})
        out.append('\nViewports seen: ' + ', '.join(str(v) for v in vp) + '.\n')
        usage_table(gui, out)
    print('\n'.join(out))
    print('\nverdicts:', {f'{c}/{m}': f'{w}/{n}' for (c, m), (w, n) in verdicts.items()})


main()
