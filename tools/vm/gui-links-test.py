#!/usr/bin/env python3
"""Exercise native Wayland URL gestures against a recording system opener."""
import argparse
import importlib.util
import json
from pathlib import Path
import shlex
import time


READER = r'''import json, os, pathlib, select, sys, termios, tty
state = pathlib.Path(sys.argv[1])
saved = termios.tcgetattr(0)
try:
    tty.setraw(0)
    cols, rows = os.get_terminal_size()
    wrapped = 'https://wrap.example/' + 'a' * cols
    output = '\033[2J\033[H\033[48;2;18;100;200m \033[0m https://visible.example/path\r\n'
    output += '  \033]8;id=docs;https://actual.example/docs\033\\Documentation\033]8;;\033\\\r\n\r\n'
    output += wrapped + '\r\n'
    os.write(1, output.encode())
    (state / 'ready.json').write_text(json.dumps(dict(pid=os.getpid(), cols=cols, rows=rows, wrapped=wrapped)))
    while True:
        if select.select([0], [], [], 0.1)[0]:
            data = os.read(0, 1024)
            if not data or b'\x03' in data: break
            with (state / 'keys').open('ab') as sink: sink.write(data)
            if b'x' in data: os.write(1, b'\033]22;crosshair\033\\')
            if b't' in data: os.write(1, b'\033]22;text\033\\')
finally:
    termios.tcsetattr(0, termios.TCSANOW, saved)
'''


def wait_for(read, condition, message):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        value = read()
        if condition(value):
            return value
        time.sleep(0.05)
    raise AssertionError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--binary', default='zig-out/bin/telar')
    options = parser.parse_args()
    spec = importlib.util.spec_from_file_location('links_driver', Path(__file__).with_name('gui-multiplexer-test.py'))
    driver = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(driver)

    class Window(driver.Window):
        def guest(self, script, *arguments, **kwargs):
            return super().guest('export PATH="$state/bin:$PATH"\n' + script, *arguments, **kwargs)

        def launch(self, reattach=False):
            self.guest('''mkdir -p "$state/bin"
cat > "$state/bin/xdg-open" <<'SH'
#!/bin/sh
printf '%s\n' "$1" >> "${TELAR_SOCKET%/*}/opened"
SH
chmod +x "$state/bin/xdg-open"
''')
            super().launch(reattach)

    driver.vm.require_running()
    window = Window('default', options.output.resolve(), options.binary)
    held = False

    def key(down):
        driver.vm.qmp('input-send-event', events=[{'type': 'key', 'data': {
            'down': down, 'key': {'type': 'qcode', 'data': 'ctrl'},
        }}])

    def button(down):
        driver.vm.qmp('input-send-event', events=[{'type': 'btn', 'data': {'down': down, 'button': 'left'}}])

    def opened():
        return window.guest('test ! -f "$state/opened" || cat "$state/opened"').splitlines()

    try:
        window.setup()
        window.action('s')
        shell = window.mark('shell')
        window.guest('cat > "$state/reader.py"', input_text=READER)
        window.type('python3 ' + shlex.quote(window.state + '/reader.py') + ' ' + shlex.quote(window.state))
        window.key('Return')
        ready = wait_for(lambda: window.guest('test ! -f "$state/ready.json" || cat "$state/ready.json"'), bool, 'Reader did not start')
        ready = json.loads(ready)
        time.sleep(0.25)
        ppm = window.output / 'grid.ppm'
        driver.vm.qmp('screendump', filename=str(ppm), format='ppm')
        magic, dimensions, maximum, pixels = ppm.read_bytes().split(b'\n', 3)
        if magic != b'P6' or maximum != b'255':
            raise AssertionError('Unexpected QEMU image format')
        width, height = map(int, dimensions.split())
        matches = [i // 3 for i in range(0, len(pixels), 3) if pixels[i:i + 3] == bytes((18, 100, 200))]
        if not matches:
            raise AssertionError('Native grid marker was not painted')
        left, right = min(i % width for i in matches), max(i % width for i in matches)
        top, bottom = min(i // width for i in matches), max(i // width for i in matches)
        cell_width, cell_height = right - left + 1, bottom - top + 1

        def move(column, row):
            x = left + (column + 0.5) * cell_width
            y = top + (row + 0.5) * cell_height
            driver.vm.qmp('input-send-event', events=[
                {'type': 'abs', 'data': {'axis': 'x', 'value': round(x * 32767 / (width - 1))}},
                {'type': 'abs', 'data': {'axis': 'y', 'value': round(y * 32767 / (height - 1))}},
            ])
            time.sleep(0.15)

        move(5, 0)
        window.screenshot('01-text-cursor')
        key(True)
        held = True
        window.screenshot('02-url-hover')
        button(True)
        time.sleep(0.1)
        if opened():
            raise AssertionError('URL opened before button release')
        button(False)
        wait_for(opened, lambda values: values == ['https://visible.example/path'], 'Visible URL did not open once')
        move(5, 1)
        window.screenshot('03-osc8-hover')
        button(True)
        button(False)
        wait_for(opened, lambda values: len(values) == 2, 'OSC 8 did not open')
        if opened()[1] != 'https://actual.example/docs':
            raise AssertionError('OSC 8 used its label instead of its destination')
        move(3, 4)
        window.screenshot('04-wrapped-hover')
        button(True)
        button(False)
        wait_for(opened, lambda values: len(values) == 3, 'Wrapped URL did not open')
        if opened()[2] != ready['wrapped']:
            raise AssertionError('Wrapped URI was truncated')
        key(False)
        held = False
        window.type('x')
        window.screenshot('05-osc22-crosshair')
        window.type('t')
        window.screenshot('06-osc22-text')
        if window.guest('cat "$state/keys"') != 'xt':
            raise AssertionError('Native link gestures leaked input to the child')
        window.detach()
        window.guest('kill -0 "$1" "$2"', str(shell['pid']), str(ready['pid']))
        window.guest('! grep -E "Validation Error|VUID-|native input capacity exceeded" "$state/gui.log"')
        (window.output / 'links.json').write_text(json.dumps(dict(
            opened=opened(), release_only=True, child_input='xt', children_survived=True,
            cell_width=cell_width, cell_height=cell_height,
        ), indent=2) + '\n')
        window.step('Visible, OSC 8 and wrapped URLs; release-only opening; cursor captures; surviving children')
        window.collect('passed')
    except Exception as error:
        window.collect('failed', str(error))
        raise
    finally:
        if held:
            button(False)
            key(False)
        window.cleanup()


if __name__ == '__main__':
    main()
