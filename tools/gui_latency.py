#!/usr/bin/env python3
"""macOS key callback -> matching terminal geometry -> successful Metal completion.

Uses an isolated runtime, cat's PTY echo, and one outstanding x/erase pair.
This measures GPU completion, not display scanout or physical keyboard latency.
The injector is test-only; it adds no benchmark branches to the application.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess

from echo_latency import percentile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('directory', type=Path, help='new directory for isolated runtime and retained results')
    parser.add_argument('--samples', type=int, default=100)
    parser.add_argument('--gap', type=float, default=0.03)
    parser.add_argument('--dense', action='store_true', help='fill 20 rows, keeping the input cell empty')
    parser.add_argument('--config', type=Path,
                        help='a config whose chrome holds still, instead of --no-config and its fixture check')
    parser.add_argument('--raw-echo', action='store_true',
                        help='echo from a raw-mode program instead of the line discipline, so other output cannot retype the line')
    parser.add_argument('--stream-size', default='3840x2160', metavar='WxH', help='size of the streamed images')
    parser.add_argument('--stream-text', action='store_true',
                        help='with --stream, redraw a text counter instead of images')
    parser.add_argument('--stream', type=float, default=0, metavar='FPS',
                        help='stream synthetic 4K RGBA Kitty images into the same pane at this rate')
    args = parser.parse_args()
    if platform.system() != 'Darwin':
        parser.error('this probe requires macOS and a graphical login session')
    if not 1 <= args.samples <= 512 or not 0 <= args.gap <= 1:
        parser.error('samples must be 1..512 and gap 0..1 seconds')
    binary = args.binary.resolve()
    directory = args.directory.resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    dylib = directory / 'probe.dylib'
    subprocess.run(['clang', '-dynamiclib', '-fobjc-arc', '-framework', 'AppKit',
                    '-framework', 'QuartzCore', str(Path(__file__).with_suffix('.m')),
                    '-o', str(dylib)], check=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith('TELAR_')}
    env.update(TELAR_SOCKET=str(directory / 'runtime.sock'),
               TELAR_HISTORY=str(directory / 'history.db'),
               TELAR_ECHO_TRACE_DIR=str(directory),
               DYLD_INSERT_LIBRARIES=str(dylib),
               TELAR_GUI_PROBE_SAMPLES=str(args.samples),
               TELAR_GUI_PROBE_GAP=str(args.gap),
               TELAR_GUI_PROBE_RESULT=str(directory / 'samples.json'))
    command = ['/bin/cat']
    echo = '/bin/cat'
    if args.raw_echo:
        echo = f"python3 '{Path(__file__).with_name('raw_echo.py')}'"
        command = ['/bin/sh', '-c', f'stty raw -echo; exec {echo}']
    if args.stream > 0:
        stream = Path(__file__).with_name('kitty_stream.py')
        raw = 'stty raw -echo; ' if args.raw_echo else ''
        command = ['/bin/sh', '-c',
                   f"{raw}python3 '{stream}' --fps {args.stream} --width {args.stream_size.split('x')[0]} --height {args.stream_size.split('x')[1]}{' --text' if args.stream_text else ''} --seconds 600 --report '{directory / 'stream.txt'}' & exec {echo}"]
    if args.dense:
        command = ['/bin/sh', '-c',
                   "printf '\033[2J\033[2;1H'; i=0; while [ $i -lt 20 ]; do "
                   "printf '%s\r\n' 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'; "
                   "i=$((i+1)); done; printf '\033[H'; exec /bin/cat"]
    try:
        with (directory / 'gui.log').open('w') as log:
            config = ['--config', str(args.config.resolve())] if args.config else ['--no-config']
            process = subprocess.Popen([str(binary), 'gui', *config, *command],
                                       env=env, stdout=log, stderr=log)
            try:
                process.wait(timeout=100)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
                raise
            if process.returncode:
                raise RuntimeError(f'GUI exited with {process.returncode}; see {directory / "gui.log"}')
    finally:
        subprocess.run([str(binary), 'server', 'stop'], env=env,
                       stdout=subprocess.DEVNULL, timeout=10, check=False)
    result = json.loads((directory / 'samples.json').read_text())
    # A streamed image is one more textured quad in every frame.
    if not args.config and result['baseline_glyphs'] != (1240 if args.dense else 0) + (1 if args.stream > 0 and not args.stream_text else 0):
        raise RuntimeError('the initial scene does not match the fixture')
    values = result['samples_ms']
    if result['failed'] or len(values) != args.samples:
        raise RuntimeError(f'incomplete probe: {len(values)}/{args.samples} samples')
    summary = dict(binary=str(binary), samples=len(values), dense=args.dense,
                   viewport=result['viewport'], baseline_glyphs=result['baseline_glyphs'],
                   p50_ms=statistics.median(values), p95_ms=percentile(values, .95),
                   p99_ms=percentile(values, .99), max_ms=max(values))
    (directory / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
