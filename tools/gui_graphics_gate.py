#!/usr/bin/env python3
"""The window's graphics performance gate (docs/performance-gates.md).

Runs the macOS key-to-GPU-completion probe (gui_latency.py) three ways: an
idle pane, the pane redrawing a text counter at --fps (the control), and the
pane streaming synthetic 3840x2160 RGBA Kitty images over shared memory at
--fps. Any pane that redraws continuously makes a key wait for the next
frame, so images are judged against the text control, not against idle; the
idle run is reported for context. It passes when:

- the window presents at least --floor distinct generations a second (a
  generation counts the first time a frame draws it), with a real margin
  under the 60 Hz a window can present, and no single run stalls under half
  of it;
- image-stream keystroke latency stays within the regression bounds of
  performance-gates.md over the control (5% at p50, 8% at p95, 10% at p99),
  and its p99 under an absolute --ceiling, so a slower control can never
  hide a regression;
- the runtime drops and resets no media and the client requests no graphics
  resync;
- idle and stream runs start from the same scene (baseline glyph count).

Upload and prepare percentiles and the GPU bytes the textures hold are
reported. Medians are over --repeats runs of each mode.

Build with `zig build -Doptimize=ReleaseFast -Ddiagnostics=true` first so
the telemetry logs this gate reads are compiled in.
"""
import argparse
import json
from pathlib import Path
import statistics
import subprocess
import sys

BOUNDS = {'p50_ms': 1.05, 'p95_ms': 1.08, 'p99_ms': 1.10}


def last_json(directory, pattern):
    lines = []
    for path in sorted(directory.glob(pattern)):
        lines += [json.loads(line) for line in path.read_text().splitlines() if line.startswith('{')]
    return lines


def counter_rate(samples, field):
    """`field` per second between the first and last telemetry line that saw any."""
    active = [sample for sample in samples if sample.get(field, 0) > 0]
    if len(active) < 2:
        return 0.0
    first, last = active[0], active[-1]
    seconds = (last['uptime_ms'] - first['uptime_ms']) / 1000
    return (last[field] - first[field]) / seconds if seconds > 0 else 0.0


def probe(binary, directory, samples, stream, text=False):
    command = [sys.executable, str(Path(__file__).with_name('gui_latency.py')), str(binary), str(directory),
               '--samples', str(samples), '--config', str(Path(__file__).with_name('gui_graphics_gate.lua')), '--raw-echo', '--settle', '3']
    if stream:
        command += ['--stream', str(stream)]
    if text:
        command += ['--stream-text']
    # A run the window never delivered keys to (focus taken by another app)
    # is repeated once in a fresh directory; the report counts retries.
    retried = 0
    while subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
        if retried == 1:
            raise RuntimeError(f'probe failed twice; see {directory}/gui.log')
        retried += 1
        directory = directory.with_name(directory.name + '-retry')
        command[3] = str(directory)
    summary = json.loads((directory / 'summary.json').read_text())
    summary['retried'] = retried
    client = last_json(directory, '*.client-*.log')
    runtime = last_json(directory, '*.runtime-*.log')
    # Without telemetry every counter below would read as zero and pass for
    # a window that presents nothing.
    if not client or not runtime:
        raise RuntimeError(f'no telemetry in {directory}: build with -Doptimize=ReleaseFast -Ddiagnostics=true')
    final = runtime[-1] if runtime else {}
    summary.update(
        presented_per_second=counter_rate(client, 'graphics_presented'),
        textures_per_second=counter_rate(client, 'graphics_textures'),
        gpu_bytes_max=max((line.get('graphics_gpu_bytes', 0) for line in client), default=0),
        resyncs=client[-1].get('graphics_resyncs', 0) if client else 0,
        media_resets=final.get('media_resets', 0),
        media_dropped_bytes=final.get('media_dropped_bytes', 0),
        media_held_reads=final.get('media_held_reads', 0),
        frames_forwarded=final.get('media_forwarded_frames', 0),
        frames_folded=final.get('media_discarded_frames', 0),
    )
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('binary', type=Path)
    parser.add_argument('directory', type=Path, help='new directory for the runs and the report')
    parser.add_argument('--samples', type=int, default=100)
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--fps', type=float, default=120)
    parser.add_argument('--floor', type=float, default=50,
                        help='presented generations a second; a 60 Hz window presents at most 60')
    parser.add_argument('--ceiling', type=float, default=16, help='absolute stream p99 key latency, ms')
    args = parser.parse_args()
    args.directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    runs = {'idle': [], 'text': [], 'stream': []}
    for index in range(args.repeats):
        runs['idle'].append(probe(args.binary, args.directory / f'idle-{index}', args.samples, 0))
        runs['text'].append(probe(args.binary, args.directory / f'text-{index}', args.samples, args.fps, text=True))
        runs['stream'].append(probe(args.binary, args.directory / f'stream-{index}', args.samples, args.fps))

    report = {'fps': args.fps, 'floor': args.floor, 'repeats': args.repeats, 'runs': runs}
    failures = []
    for key, bound in BOUNDS.items():
        idle = statistics.median(run[key] for run in runs['idle'])
        control = statistics.median(run[key] for run in runs['text'])
        streamed = statistics.median(run[key] for run in runs['stream'])
        report[key] = {'idle': idle, 'text': control, 'stream': streamed, 'ratio': streamed / control, 'bound': bound}
        if streamed > control * bound:
            failures.append(f'{key} {streamed:.3f} ms is over {bound:.2f}x the text control {control:.3f} ms')
    rate = statistics.median(run['presented_per_second'] for run in runs['stream'])
    report['presented_per_second'] = rate
    report['textures_per_second'] = statistics.median(run['textures_per_second'] for run in runs['stream'])
    report['gpu_bytes_max'] = max(run['gpu_bytes_max'] for run in runs['stream'])
    for name in ('prepare_ms', 'upload_ms'):
        traces = [run[name] for run in runs['stream'] if name in run]
        if traces:
            report[name] = {key: statistics.median(trace[key] for trace in traces) for key in ('p50', 'p95', 'p99', 'max')}
    if rate < args.floor:
        failures.append(f'{rate:.1f} presented generations/s is under the {args.floor} floor')
    # A median hides one stalled run; a stall is a bug, not noise.
    slowest = min(run['presented_per_second'] for run in runs['stream'])
    if slowest < args.floor / 2:
        failures.append(f'a stream run presented {slowest:.1f} generations/s, under half the floor')
    if report['p99_ms']['stream'] > args.ceiling:
        failures.append(f"stream p99 {report['p99_ms']['stream']:.3f} ms is over the {args.ceiling} ms ceiling")
    # The text control adds its counter's digits; idle and image runs must
    # match exactly, since image quads never count as glyphs.
    baselines = {run['baseline_glyphs'] for mode in ('idle', 'stream') for run in runs[mode]}
    if len(baselines) != 1:
        failures.append(f'idle and stream runs started from different scenes: baseline glyphs {sorted(baselines)}')
    for run in runs['stream']:
        if run['media_resets'] or run['media_dropped_bytes']:
            failures.append(f"media reset {run['media_resets']} times and dropped {run['media_dropped_bytes']} bytes")
        if run['resyncs']:
            failures.append(f"the client requested {run['resyncs']} graphics resyncs")
    report['failures'] = failures
    (args.directory / 'gate.json').write_text(json.dumps(report, indent=2) + '\n')
    shown = ('p50_ms', 'p95_ms', 'p99_ms', 'presented_per_second', 'textures_per_second', 'gpu_bytes_max',
             'prepare_ms', 'upload_ms', 'failures')
    print(json.dumps({key: report[key] for key in shown if key in report}, indent=2))
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
