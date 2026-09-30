#!/usr/bin/env python3
"""Measure key-to-PTY latency in the Linux window, idle and while the same
pane streams Kitty images over shared memory.

A reader in the pane puts the tty in raw mode, optionally runs
tools/kitty_stream.py into the same tty, and stamps every byte it receives
with CLOCK_MONOTONIC. A driver in the guest stamps each key before `wtype`
sends it through the compositor. The difference includes wtype's own start,
which is the same in both runs, so the runs are compared with each other,
not read as absolute latency. The window's GPU completion is not part of it:
the check is that uploads and image frames never delay a key on its way to
the child.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import shlex
import time


READER = '''import os, pathlib, select, subprocess, sys, termios, time, tty
state = pathlib.Path(sys.argv[1])
stream = sys.argv[2:]
saved = termios.tcgetattr(0)
child = None
try:
    tty.setraw(0)
    os.write(1, b"\\033[2J\\033[H")
    if stream:
        child = subprocess.Popen([sys.executable] + stream, stdout=1)
    with (state / 'stamps').open('w', buffering=1) as output:
        (state / 'ready').touch()
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            if select.select([0], [], [], 0.1)[0]:
                data = os.read(0, 1024)
                now = time.monotonic_ns()
                if not data or b'q' in data: break
                for _ in data:
                    output.write(f'{now}\\n')
finally:
    if child is not None:
        child.kill()
    termios.tcsetattr(0, termios.TCSANOW, saved)
'''

DRIVER = '''import json, os, pathlib, subprocess, sys, time
state = pathlib.Path(sys.argv[1])
samples, settle = int(sys.argv[2]), float(sys.argv[3])
stamps = state / 'stamps'
time.sleep(settle)
latencies = []
for index in range(samples):
    before = len(stamps.read_text().splitlines())
    sent = time.monotonic_ns()
    subprocess.run(['wtype', 'j'], check=True)
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        lines = stamps.read_text().splitlines()
        if len(lines) > before:
            latencies.append((int(lines[before]) - sent) / 1e6)
            break
        time.sleep(0.0005)
    time.sleep(0.05)
print(json.dumps(latencies))
'''


def percentiles(values):
    ordered = sorted(values)
    pick = lambda fraction: ordered[min(len(ordered) - 1, int(fraction * len(ordered)))]
    return {'count': len(ordered), 'p50_ms': pick(0.50), 'p95_ms': pick(0.95), 'p99_ms': pick(0.99), 'max_ms': ordered[-1]}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('output', type=Path)
    parser.add_argument('--binary', default='zig-out/bin/telar')
    parser.add_argument('--samples', type=int, default=100)
    parser.add_argument('--width', type=int, default=1920)
    parser.add_argument('--height', type=int, default=1080)
    parser.add_argument('--fps', type=float, default=60)
    options = parser.parse_args()
    options.output = options.output.resolve()
    path = Path(__file__).with_name('gui-multiplexer-test.py')
    spec = importlib.util.spec_from_file_location('latency_driver', path)
    driver = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(driver)
    driver.vm.require_running()
    report = {'width': options.width, 'height': options.height, 'fps': options.fps}
    for mode in ('idle', 'stream'):
        window = driver.Window('default', options.output / mode, options.binary)
        try:
            window.setup()
            window.guest('cat > "$state/reader.py"', input_text=READER)
            window.guest('cat > "$state/driver.py"', input_text=DRIVER)
            command = ['python3', window.state + '/reader.py', window.state]
            if mode == 'stream':
                command += ['--width', str(options.width), '--height', str(options.height),
                            '--fps', str(options.fps), '--seconds', '110']
            # The guest's checkout; the pane's shell expands its home.
            stream = ' "$HOME/src/telar/tools/kitty_stream.py"' if mode == 'stream' else ''
            words = [shlex.quote(part) for part in command]
            window.type(' '.join(words[:3]) + stream + ' ' + ' '.join(words[3:]))
            window.key('Return')
            deadline = time.monotonic() + 5
            while window.guest('test ! -f "$state/ready" || printf ready') != 'ready':
                if time.monotonic() >= deadline:
                    raise RuntimeError('PTY reader did not start')
                time.sleep(0.05)
            window.focus()
            latencies = json.loads(window.guest('python3 "$state/driver.py" "$state" "$1" 3', str(options.samples),
                                                timeout=options.samples + 60))
            report[mode] = percentiles(latencies)
            # The last client telemetry line, when the build has diagnostics.
            telemetry = window.guest('cat "$state"/*.client-*.log 2>/dev/null | grep "^{" | tail -1 || true')
            if telemetry.strip():
                line = json.loads(telemetry)
                report[mode].update({key: line.get(key) for key in (
                    'graphics_images', 'graphics_textures', 'graphics_presented', 'graphics_gpu_bytes', 'uptime_ms')})
            window.screenshot(mode)
            window.guest('! grep -E "Validation Error|VUID-" "$state/gui.log"')
            window.type('q')
            window.collect('passed')
        except Exception as error:
            window.collect('failed', str(error))
            raise
        finally:
            window.cleanup()
    (options.output / 'latency.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
