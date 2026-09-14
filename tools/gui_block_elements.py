#!/usr/bin/env python3
"""Capture Unicode block elements drawn by a child against an isolated macOS runtime.

The fixture prints the Claude Code mascot, halves, eighths, quadrants and the
three shades with the bundled JetBrains Mono at the line height of
examples/gui.lua, so the capture shows whether ink meets the cell edges.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time

from gui_multiplexer import Actions


def lines():
    sample = [
        'Block elements',
        '▐▛███▜▌',
        '▝▜█████▛▘',
        '  ▘▘ ▝▝',
        '█▀▄ ░▒▓ ▌▐',
        '▁▂▃▄▅▆▇█ ▏▎▍▌▋▊▉█ ▔▕',
        '▖▗▘▙▚▛▜▝▞▟',
        '░░░░ ▒▒▒▒ ▓▓▓▓ ████',
        '░░░░ ▒▒▒▒ ▓▓▓▓ ████',
        '│▌▐│ ─▀▄─ ╭▛▜╮',
    ]
    sample.extend(f'{0x2580 + row * 16:04X}: ' + ''.join(chr(0x2580 + row * 16 + col) for col in range(16))
                  for row in range(2))
    return sample


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('directory', type=Path, help='new short /tmp directory')
    options = parser.parse_args()
    binary = options.binary.resolve()
    directory = options.directory.resolve()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    config = directory / 'config.lua'
    config.write_text('''return { api_version = 2, theme = 'vesper',
      gui = { font = { family = 'JetBrains Mono', size = 15, line_height = 1.15 },
              cursor = { blink = false } } }
''')
    sample = directory / 'blocks.txt'
    sample.write_text('\n'.join(lines()) + '\n')
    actions = Actions(directory)
    actions.text(f'clear; cat {sample}; touch {directory / "shown"}')
    actions.key('\r', 36)
    actions.items.append(dict(wait=str(directory / 'shown')))
    actions.items.extend([{}] * 6)
    actions.capture('blocks')
    script = directory / 'actions.json'
    script.write_text(json.dumps(actions.items))
    library = directory / 'driver.dylib'
    subprocess.run(['clang', '-dynamiclib', '-fobjc-arc', '-framework', 'AppKit',
                    str(Path(__file__).with_name('gui_actions.m')), '-o', str(library)], check=True)
    env = {key: value for key, value in os.environ.items()
           if not key.startswith('TELAR_') and key != 'DYLD_INSERT_LIBRARIES'}
    env.update(TELAR_SOCKET=str(directory / 'runtime.sock'), TELAR_HISTORY=str(directory / 'history.db'))
    server_log = (directory / 'server.log').open('w')
    server = subprocess.Popen([str(binary), 'server', '--no-config'], env=env, cwd=directory,
                              stdout=server_log, stderr=server_log)
    try:
        deadline = time.monotonic() + 5
        while not (directory / 'runtime.sock').exists():
            if server.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError('The isolated runtime did not start; see server.log')
            time.sleep(0.02)
        with (directory / 'gui.log').open('w') as log:
            subprocess.run([str(binary), 'gui', '--config', str(config), '/bin/sh'],
                           env=dict(env, DYLD_INSERT_LIBRARIES=str(library), TELAR_GUI_ACTIONS=str(script)),
                           cwd=directory, stdout=log, stderr=log, timeout=45, check=True)
        assert (directory / 'blocks.png').exists()
        print(directory / 'blocks.png')
    finally:
        subprocess.run([str(binary), 'server', 'stop'], env=env,
                       stdout=subprocess.DEVNULL, timeout=10, check=False)
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait()
        server_log.close()


if __name__ == '__main__':
    main()
