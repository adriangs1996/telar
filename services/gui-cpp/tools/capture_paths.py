import argparse
import json
from pathlib import Path
import shutil

import capture_history as native_capture


def path_script(directory, settings):
    settle_ticks = 10
    input_ticks = 5
    readback_ticks = 20
    actions = [dict(activate=True, resize=settings.viewport), *([{}] * settle_ticks),
               dict(key='\x02', unmodified='b', code=11, ctrl=True), dict(key='f', code=3),
               *([{}] * input_ticks)]
    if settings.cursor_row:
        command = f"printf '\\033[2J\\033[{settings.cursor_row};11H'"
        prefix = [dict(text=command), dict(key='\r', code=36), *([{}] * settle_ticks)]
        actions[1 + settle_ticks:1 + settle_ticks] = prefix
    if settings.query:
        actions.extend([dict(text=settings.query), *([{}] * settle_ticks)])
    for _ in range(settings.selected_row):
        actions.extend([dict(key='\uf701', code=125), *([{}] * input_ticks)])
    actions.extend([dict(resize=[settings.viewport[0] + 1, settings.viewport[1]]), *([{}] * input_ticks),
                    dict(resize=settings.viewport), *([{}] * settle_ticks),
                    dict(record=str(directory / 'native-state.json')), dict(signal=str(directory / 'settled.at')),
                    *([{}] * readback_ticks)])
    (directory / 'actions.json').write_text(json.dumps(actions) + '\n')


def main():
    parser = argparse.ArgumentParser(description='Capture the original and Qt native path pickers with the same input and viewport')
    parser.add_argument('zig_binary', type=Path)
    parser.add_argument('cpp_gui', type=Path)
    parser.add_argument('output_directory', type=Path)
    parser.add_argument('--viewport', type=int, nargs=2, default=[1180, 720])
    parser.add_argument('--query', default='')
    parser.add_argument('--selected-row', type=int, default=0)
    parser.add_argument('--cursor-row', type=int, default=0)
    parser.add_argument('--capture-timeout', type=float, default=35)
    options = parser.parse_args()
    if options.selected_row < 0:
        parser.error('Selected row must not be negative')
    options.empty_history = True
    options.history_response = 'normal'
    output = options.output_directory.resolve()
    output.mkdir(parents=True, exist_ok=False)
    work = output / 'work'
    work.mkdir()
    (work / 'src').mkdir()
    for name in ['main.cpp', "a b'c.txt", 'mañana.txt', 'terminal.hpp']:
        (work / 'src' / name).write_text('fixture\n')
    for index in range(12):
        (work / f'file-{index:02}.txt').write_text('fixture\n')
    (output / 'fixture.zsh_history').write_text('')
    (output / 'gui.lua').write_text('''return {
  api_version = 2,
  theme = "shade",
  client = { sidebar = { visible = false } },
  gui = {
    font = { family = "JetBrains Mono", size = 15 },
    window = { padding = { x = 0, y = 0 }, background_opacity = 1 },
    cursor = { blink = false },
  },
}
''')
    native_capture.prepare_probe(output)
    shutil.copy2(Path(__file__), output / 'path_driver.py')
    native_capture.script = path_script
    result = dict(scope='Presented Cocoa path picker captures with original and C++ clients. Pixel comparisons do not establish full parity.',
                  query=options.query, selected_row=options.selected_row, cursor_row=options.cursor_row,
                  binary_sha256=dict(zig=native_capture.sha(options.zig_binary), qt=native_capture.sha(options.cpp_gui)), clients={})
    try:
        for kind in ['zig', 'qt']:
            result['clients'][kind] = native_capture.capture(kind, options.zig_binary.resolve(), options.cpp_gui.resolve(), output, options)
            observation = json.loads((output / kind / 'window.png.observation.json').read_text())
            if not observation['app_active'] or not observation['window_key'] or observation['presented_time'] <= observation['last_input_time']:
                raise RuntimeError(f'{kind}: capture did not follow the final active input geometry')
            print('Captured', kind, flush=True)
        result['comparison'] = native_capture.compare(output)
    finally:
        names = ['path_driver.py', 'capture_driver.py', 'history_actions.m', 'history_capture.m', 'gui_view.h', 'gui.lua']
        result['source_sha256'] = {name: native_capture.sha(output / name) for name in names}
        (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result['comparison']), flush=True)


if __name__ == '__main__':
    main()
