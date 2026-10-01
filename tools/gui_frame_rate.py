#!/usr/bin/env python3
"""macOS: presented frames a second while one pane floods, in an isolated runtime.

Opens `telar gui` running `yes` in its only pane, waits for the window to
settle, then counts delivered presentations for --seconds. Reports the
display's refresh rate, the interval the window reported and paced at, the
presented rate, the cell frames a second the runtime sent (client telemetry,
so build with `-Doptimize=ReleaseFast -Ddiagnostics=true`) and how long a
frame took from preparation to GPU completion. A window presents at most at
its display's rate, or at `gui.max_fps` below it (docs/flows/frame-pacing.md).

The window opens where the window manager puts it. With AeroSpace,
--aerospace-monitor moves only the test window to that monitor first.
--source names the tree the binary was built from, whose telar_gui.h the
injector compiles against, so a build from before display pacing can be
compared. The directory holds the runtime socket, so keep its path short.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import subprocess
import time

FLOOD = "sleep 1; exec yes 'the quick brown fox jumps over the lazy dog 0123456789 abcdefghijklmnopqrstuvwxyz'"


def telemetry(directory):
    lines = []
    for path in sorted(directory.glob('*.client-*.log')):
        lines += [json.loads(line) for line in path.read_text().splitlines() if line.startswith('{')]
    return lines


def counter_rate(samples, field):
    """`field` per second, skipping the first and last second: startup and closing."""
    active = [sample for sample in samples if sample.get(field, 0) > 0]
    if len(active) < 3:
        return 0.0
    first, last = active[1], active[-2]
    seconds = (last['uptime_ms'] - first['uptime_ms']) / 1000
    return (last[field] - first[field]) / seconds if seconds > 0 else 0.0


def move_window(pid, monitor, directory):
    # AeroSpace tiles a new window back onto its workspace; move only this
    # one, found by the test process's pid.
    for _ in range(40):
        time.sleep(0.25)
        found = subprocess.run(['aerospace', 'list-windows', '--monitor', 'all', '--pid', str(pid),
                                '--format', '%{window-id}'], capture_output=True, text=True).stdout.split()
        if found:
            subprocess.run(['aerospace', 'move-node-to-monitor', '--window-id', found[0], str(monitor)],
                           capture_output=True, check=True)
            return
    raise RuntimeError(f'AeroSpace never listed the window; see {directory / "gui.log"}')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('binary', type=Path)
    parser.add_argument('directory', type=Path, help='new, short directory for the isolated runtime and results')
    parser.add_argument('--source', type=Path, default=Path(__file__).resolve().parents[1],
                        help='the tree the binary was built from (default: this one)')
    parser.add_argument('--config', type=Path, help='a config to open the window with, e.g. one setting gui.max_fps')
    parser.add_argument('--seconds', type=float, default=6)
    parser.add_argument('--aerospace-monitor', type=int)
    args = parser.parse_args()
    if platform.system() != 'Darwin':
        parser.error('this probe requires macOS and a graphical login session')
    directory = args.directory.resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    for name in ('config', 'data', 'runtime'):
        (directory / name).mkdir(mode=0o700)
    native = args.source.resolve() / 'src' / 'gui' / 'native'
    legacy = 'display_interval' not in (native / 'telar_gui.h').read_text()
    dylib = directory / 'probe.dylib'
    subprocess.run(['clang', '-dynamiclib', '-fobjc-arc', '-framework', 'AppKit', '-framework', 'QuartzCore',
                    '-I', str(native), *(['-DTELAR_GUI_RATE_LEGACY'] if legacy else []),
                    str(Path(__file__).with_suffix('.m')), '-o', str(dylib)], check=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('TELAR_', 'XDG_'))}
    env.update(TELAR_SOCKET=str(directory / 'runtime.sock'), TELAR_HISTORY=str(directory / 'history.db'),
               XDG_CONFIG_HOME=str(directory / 'config'), XDG_DATA_HOME=str(directory / 'data'),
               XDG_RUNTIME_DIR=str(directory / 'runtime'), DYLD_INSERT_LIBRARIES=str(dylib),
               TELAR_GUI_RATE_SECONDS=str(args.seconds), TELAR_GUI_RATE_RESULT=str(directory / 'probe.json'))
    binary = args.binary.resolve()
    config = ['--config', str(args.config.resolve())] if args.config else ['--no-config']
    try:
        with (directory / 'gui.log').open('w') as log:
            process = subprocess.Popen([str(binary), 'gui', *config, '/bin/sh', '-c', FLOOD],
                                       env=env, stdout=log, stderr=log)
            try:
                if args.aerospace_monitor:
                    move_window(process.pid, args.aerospace_monitor, directory)
                process.wait(timeout=120)
            except BaseException:
                process.kill()
                process.wait()
                raise
    finally:
        subprocess.run([str(binary), 'server', 'stop'], env=env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20, check=False)
    result = json.loads((directory / 'probe.json').read_text())
    samples = telemetry(directory)
    if not samples:
        raise RuntimeError(f'no telemetry in {directory}: build with -Doptimize=ReleaseFast -Ddiagnostics=true')
    result['cell_frames_per_second'] = round(counter_rate(samples, 'frames'), 1)
    (directory / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
