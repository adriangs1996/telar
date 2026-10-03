#!/usr/bin/env python3
"""Paired, alternated key-to-verified-pixel runs of two telar builds through
tools/gui_tui_latency.py in GUI mode: one idle pane (single) and one pane
typed into while three others flood output (splits-load, 4 panes).

usage: pair_load.py A_BIN B_BIN OUT_DIR PAIRS [--diagnostics]

Each pair runs A then B, the next B then A, each as one round of 100 samples
after 20 warmups at a fixed 1900x1100 render target. The GUI process's peak
RSS and CPU time are sampled with ps. Prints per-case medians, the paired
ratio and the win count for p50, p95 and p99.
"""
import json, os, statistics, subprocess, sys, threading, time
from pathlib import Path

TOOLS = Path(os.environ.get("TELAR_TOOLS", Path(__file__).resolve().parents[4] / "tools"))


def sample_process(binary, stop, out):
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


def run(binary, directory, diagnostics):
    command = [sys.executable, str(TOOLS / 'gui_tui_latency.py'), str(binary), str(directory), '--mode', 'gui',
               '--cases', 'single', 'splits-load', '--panes', '4', '--rounds', '1', '--samples', '100',
               '--viewport', '1900', '1100', '--float-windows']
    env = dict(os.environ)
    for key in ('SSH_CONNECTION', 'SSH_CLIENT', 'SSH_TTY'):
        env.pop(key, None)
    env['DEVELOPER_DIR'] = '/Library/Developer/CommandLineTools'
    if diagnostics:
        env['TGB_DRAW_DIAGNOSTICS'] = '1'
    stop = threading.Event()
    usage = {}
    sampler = threading.Thread(target=sample_process, args=(binary, stop, usage), daemon=True)
    sampler.start()
    try:
        result = subprocess.run(command, capture_output=True, text=True, env=env)
    finally:
        stop.set()
        sampler.join()
    if result.returncode != 0:
        raise RuntimeError(f'probe failed for {binary}: {result.stderr[-3000:]}')
    report = json.loads((directory / 'comparison.json').read_text())
    out = {}
    for run_ in report['runs']:
        out[run_['case']] = dict(run_['summary'], viewport=run_.get('viewport'), pty_cells=run_.get('pty_cells'))
    out['usage'] = usage
    return out


def main():
    a, b, out, pairs = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve(), Path(sys.argv[3]).resolve(), int(sys.argv[4])
    diagnostics = '--diagnostics' in sys.argv[5:]
    out.mkdir(parents=True, exist_ok=True)
    runs = []
    for index in range(pairs):
        order = [('A', a), ('B', b)] if index % 2 == 0 else [('B', b), ('A', a)]
        for label, binary in order:
            directory = out / f'load-p{index}-{label}'
            summary = run(binary, directory, diagnostics)
            summary.update(pair=index, build=label)
            runs.append(summary)
            (out / 'runs.json').write_text(json.dumps(runs, indent=1) + '\n')
            print(json.dumps({'pair': index, 'build': label, 'single': {k: round(summary['single'][k], 3) for k in ('p50_ms', 'p95_ms', 'p99_ms')},
                              'splits-load': {k: round(summary['splits-load'][k], 3) for k in ('p50_ms', 'p95_ms', 'p99_ms')}, 'usage': summary['usage']}), flush=True)
    report(runs, out)


def report(runs, out):
    lines = []
    for case in ('single', 'splits-load'):
        for metric in ('p50_ms', 'p95_ms', 'p99_ms'):
            by = {label: [r[case][metric] for r in sorted(runs, key=lambda r: r['pair']) if r['build'] == label] for label in 'AB'}
            ratios = [bb / aa - 1 for aa, bb in zip(by['A'], by['B'])]
            lines.append(f"{case:12}{metric:8}{statistics.median(by['A']):9.3f}{statistics.median(by['B']):9.3f}  "
                         f"{statistics.median(ratios) * 100:+7.1f}%  {sum(r < 0 for r in ratios)}/{len(ratios)}")
    text = f"{'case':12}{'metric':8}{'A ms':>9}{'B ms':>9}  {'paired':>8}  B wins\n" + '\n'.join(lines) + '\n'
    (out / 'report.txt').write_text(text)
    print(text)


if __name__ == '__main__':
    main()
