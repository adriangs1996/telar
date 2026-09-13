#!/usr/bin/env python3
"""Hold a virtual hardware key and verify Wayland repeat and release at the PTY."""
import argparse
import importlib.util
import json
from pathlib import Path
import shlex
import time


READER = '''import os, pathlib, select, sys, termios, time, tty
state = pathlib.Path(sys.argv[1])
saved = termios.tcgetattr(0)
try:
    tty.setraw(0)
    os.write(1, "\\033[2J\\033[HDejaVu Sans Mono fallback: \\uf07b \\uf115 \\ue7a8 \\U000f035b\\r\\n".encode())
    with (state / 'keys').open('wb', buffering=0) as output:
        (state / 'ready').touch()
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if select.select([0], [], [], 0.1)[0]:
                data = os.read(0, 1024)
                if not data or b'\\x03' in data: break
                output.write(data)
finally:
    termios.tcsetattr(0, termios.TCSANOW, saved)
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--binary', default='zig-out/bin/telar')
    options = parser.parse_args()
    options.output = options.output.resolve()
    path = Path(__file__).with_name('gui-multiplexer-test.py')
    spec = importlib.util.spec_from_file_location('repeat_driver', path)
    driver = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(driver)
    driver.vm.require_running()
    window = driver.Window('default', options.output, options.binary)
    held = False

    def key(down):
        driver.vm.qmp('input-send-event', events=[{
            'type': 'key', 'data': {'down': down, 'key': {'type': 'qcode', 'data': 'j'}},
        }])

    try:
        window.setup()
        window.guest('cat > "$state/reader.py"', input_text=READER)
        window.type('python3 ' + shlex.quote(window.state + '/reader.py') + ' ' + shlex.quote(window.state))
        window.key('Return')
        deadline = time.monotonic() + 5
        while window.guest('test ! -f "$state/ready" || printf ready') != 'ready':
            if time.monotonic() >= deadline:
                raise RuntimeError('PTY reader did not start')
            time.sleep(0.05)
        window.focus()
        key(True)
        held = True
        time.sleep(1.2)
        key(False)
        held = False
        time.sleep(0.15)
        first = window.guest('cat "$state/keys"')
        if len(first) < 3 or set(first) != {'j'}:
            raise AssertionError(f'Held key did not repeat: {first!r}')
        time.sleep(0.5)
        released = window.guest('cat "$state/keys"')
        if released != first:
            raise AssertionError('Repeat continued after key release')
        window.screenshot('icons-and-repeat')
        result = dict(count=len(first), bytes=first, release_stopped=True)
        (window.output / 'repeat.json').write_text(json.dumps(result, indent=2) + '\n')
        window.step(f'held j delivered {len(first)} bytes and stopped on release')
        window.guest('! grep -E "Validation Error|VUID-|native input capacity exceeded" "$state/gui.log"')
        window.collect('passed')
    except Exception as error:
        window.collect('failed', str(error))
        raise
    finally:
        if held:
            key(False)
        window.cleanup()


if __name__ == '__main__':
    main()
