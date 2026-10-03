#!/usr/bin/env python3
"""Paired, alternated key-to-GPU-completion runs of two telar builds.

usage: pair_gui.py A_BIN B_BIN OUT_DIR PAIRS VARIANT [VARIANT ...]

Variants (all through tools/gui_latency.py with the graphics gate config,
raw echo and a 3 s settle):
  idle      one idle pane
  dense     20 rows of text behind the typed cell
  text120   the same pane redraws a text counter at 120 Hz
  image120  the same pane streams 3840x2160 RGBA images at 120 Hz
Each pair runs A then B, the next B then A. Per run the probe's p50/p95/p99
of key -> GPU completion, its prepare_ms trace, and the client's peak RSS
and CPU time (sampled with ps) are kept. Prints per-variant medians, the
paired ratio and the win count for p50, p95 and p99.
"""
import json, os, statistics, subprocess, sys, threading, time
from pathlib import Path

TOOLS = Path(os.environ.get("TELAR_TOOLS", Path(__file__).resolve().parents[4] / "tools"))
VARIANTS = {
    'idle': [],
    'dense': ['--dense'],
    'text120': ['--stream', '120', '--stream-text'],
    'image120': ['--stream', '120'],
}


def sample_process(binary, stop, out):
    """Peak RSS (KiB) and last cputime of the `BIN gui` process while it runs."""
    while not stop.is_set():
        try:
            rows = subprocess.run(['ps', '-axo', 'pid=,rss=,cputime=,command='], capture_output=True, text=True).stdout
        except OSError:
            break
        for row in rows.splitlines():
            parts = row.split(None, 3)
            if len(parts) == 4 and parts[3].startswith(str(binary) + ' gui'):
                out['rss_kib'] = max(out.get('rss_kib', 0), int(parts[1]))
                out['cputime'] = parts[2]
        time.sleep(0.25)


def run(binary, directory, variant, tools):
    gate = tools / 'gui_graphics_gate.py'
    command = [sys.executable, str(tools / 'gui_latency.py'), str(binary), str(directory),
               '--samples', '100', '--config', str(tools / 'gui_graphics_gate.lua'), '--raw-echo', '--settle', '3',
               *VARIANTS[variant]]
    stop = threading.Event()
    usage = {}
    sampler = threading.Thread(target=sample_process, args=(binary, stop, usage), daemon=True)
    sampler.start()
    try:
        result = subprocess.run(command, capture_output=True, text=True)
    finally:
        stop.set()
        sampler.join()
    if result.returncode != 0:
        # A run the window never delivered keys to, or whose scene did not
        # settle, is repeated once in a fresh directory, as the gate does.
        if directory.name.endswith('-retry'):
            raise RuntimeError(f'probe failed twice for {binary} {variant}: {result.stderr[-2000:]}')
        print(json.dumps({'retry': directory.name, 'error': result.stderr.strip().splitlines()[-1:]}), flush=True)
        summary = run(binary, directory.with_name(directory.name + '-retry'), variant, tools)
        summary['retried'] = True
        return summary
    summary = json.loads((directory / 'summary.json').read_text())
    summary['usage'] = usage
    return summary


def main():
    a, b, out, pairs = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve(), Path(sys.argv[3]).resolve(), int(sys.argv[4])
    variants = sys.argv[5:]
    out.mkdir(parents=True, exist_ok=True)
    tools = TOOLS.resolve()
    runs = []
    for index in range(pairs):
        for variant in variants:
            order = [('A', a), ('B', b)] if index % 2 == 0 else [('B', b), ('A', a)]
            for label, binary in order:
                directory = out / f'{variant}-p{index}-{label}'
                summary = run(binary, directory, variant, tools)
                summary.update(pair=index, build=label, variant=variant)
                runs.append(summary)
                (out / 'runs.json').write_text(json.dumps(runs, indent=1) + '\n')
                print(json.dumps({k: summary[k] for k in ('variant', 'pair', 'build', 'p50_ms', 'p95_ms', 'p99_ms', 'max_ms')}
                                 | {'usage': summary['usage']}), flush=True)
    report(runs, out)


def report(runs, out):
    lines = []
    for variant in sorted({r['variant'] for r in runs}):
        for metric in ('p50_ms', 'p95_ms', 'p99_ms'):
            by = {label: [r[metric] for r in sorted(runs, key=lambda r: r['pair']) if r['variant'] == variant and r['build'] == label] for label in 'AB'}
            ratios = [bb / aa - 1 for aa, bb in zip(by['A'], by['B'])]
            lines.append(f"{variant:10}{metric:8}{statistics.median(by['A']):9.3f}{statistics.median(by['B']):9.3f}  "
                         f"{statistics.median(ratios) * 100:+7.1f}%  {sum(r < 0 for r in ratios)}/{len(ratios)}")
    text = f"{'variant':10}{'metric':8}{'A ms':>9}{'B ms':>9}  {'paired':>8}  B wins\n" + '\n'.join(lines) + '\n'
    (out / 'report.txt').write_text(text)
    print(text)


if __name__ == '__main__':
    main()
