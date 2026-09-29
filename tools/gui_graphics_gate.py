#!/usr/bin/env python3
"""The window's graphics performance gate (docs/performance-gates.md).

Runs the macOS key-to-GPU-completion probe (gui_latency.py) three ways: an
idle pane, the pane redrawing a text counter at --fps (the control), and the
pane streaming synthetic 3840x2160 RGBA Kitty images over shared memory at
--fps. Any pane that redraws continuously makes a key wait for the next
frame, so images are judged against the text control, not against idle; the
idle run is reported for context. It passes when the window turns at least
--floor generations a second into textures, the runtime drops and resets no
media, and image-stream keystroke latency stays within the regression bounds
of performance-gates.md over the control: 5% at p50, 8% at p95, 10% at p99
(medians over --repeats runs of each mode).

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


def texture_rate(samples):
    """Textures per second between the first and last telemetry line that saw any."""
    active = [sample for sample in samples if sample.get('graphics_textures', 0) > 0]
    if len(active) < 2:
        return 0.0
    first, last = active[0], active[-1]
    seconds = (last['uptime_ms'] - first['uptime_ms']) / 1000
    return (last['graphics_textures'] - first['graphics_textures']) / seconds if seconds > 0 else 0.0


def probe(binary, directory, samples, stream, text=False):
    command = [sys.executable, str(Path(__file__).with_name('gui_latency.py')), str(binary), str(directory),
               '--samples', str(samples), '--config', str(Path(__file__).with_name('gui_graphics_gate.lua')), '--raw-echo']
    if stream:
        command += ['--stream', str(stream)]
    if text:
        command += ['--stream-text']
    subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
    summary = json.loads((directory / 'summary.json').read_text())
    client = last_json(directory, '*.client-*.log')
    runtime = last_json(directory, '*.runtime-*.log')
    final = runtime[-1] if runtime else {}
    summary.update(
        textures_per_second=texture_rate(client),
        upload_avg_us=client[-1].get('graphics_upload_avg_us', 0) if client else 0,
        upload_max_us=client[-1].get('graphics_upload_max_us', 0) if client else 0,
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
    parser.add_argument('--floor', type=float, default=58)
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
    rate = statistics.median(run['textures_per_second'] for run in runs['stream'])
    report['textures_per_second'] = rate
    if rate < args.floor:
        failures.append(f'{rate:.1f} textures/s is under the {args.floor} floor')
    for run in runs['stream']:
        if run['media_resets'] or run['media_dropped_bytes']:
            failures.append(f"media reset {run['media_resets']} times and dropped {run['media_dropped_bytes']} bytes")
    report['failures'] = failures
    (args.directory / 'gate.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({key: report[key] for key in ('p50_ms', 'p95_ms', 'p99_ms', 'textures_per_second', 'failures')}, indent=2))
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
