import argparse
import json
from pathlib import Path
import shutil
import sys

import capture_history as native_capture


def suggestion_script(directory, settings):
    settle_ticks = 10
    input_ticks = 5
    readback_ticks = 20
    actions = [dict(activate=True, resize=settings.viewport), *([{}] * settle_ticks),
               dict(key='\x02', unmodified='b', code=11, ctrl=True), dict(key='g', code=5),
               *([{}] * input_ticks), dict(key='a', code=0, cmd=True)]
    if settings.state == 'parent':
        actions.extend([dict(text='>Suggest a command'), *([{}] * input_ticks), dict(key='\r', code=36), *([{}] * input_ticks)])
    actions.extend([dict(key='a', code=0, cmd=True), dict(text=settings.query), *([{}] * settle_ticks)])
    if settings.state not in ['idle', 'parent']:
        actions.extend([dict(key='\r', code=36), *([{}] * settle_ticks)])
    actions.extend([dict(resize=[settings.viewport[0] + 1, settings.viewport[1]]), *([{}] * input_ticks),
                    dict(resize=settings.viewport), *([{}] * settle_ticks),
                    dict(record=str(directory / 'native-state.json')), dict(signal=str(directory / 'settled.at')),
                    *([{}] * readback_ticks)])
    (directory / 'actions.json').write_text(json.dumps(actions) + '\n')


def main():
    parser = argparse.ArgumentParser(description='Capture presented native suggestion panels from the original and Qt clients')
    parser.add_argument('zig_binary', type=Path)
    parser.add_argument('cpp_gui', type=Path)
    parser.add_argument('output_directory', type=Path)
    parser.add_argument('--viewport', type=int, nargs=2, default=[1180, 720])
    parser.add_argument('--state', choices=['idle', 'unavailable', 'ready', 'failed', 'timeout', 'waiting', 'shortened', 'parent'], default='idle')
    parser.add_argument('--capture-timeout', type=float, default=35)
    options = parser.parse_args()
    options.empty_history = True
    options.history_response = 'normal'
    options.runtime_configuration = True
    task = dict(shortened='long', unavailable='ready', parent='ready').get(options.state, options.state)
    options.query = '?fixture:' + task
    output = options.output_directory.resolve()
    output.mkdir(parents=True, exist_ok=False)
    (output / 'work').mkdir()
    (output / 'fixture.zsh_history').write_text('')
    fixture = Path(__file__).resolve().parents[1] / 'tests/suggestion_engine_fixture.py'
    provider = [sys.executable, str(fixture), str(output / 'suggestion-ran')]
    engine = '' if options.state == 'unavailable' else ', engine = {timeout_ms=' + ('1000' if options.state == 'timeout' else '30000') + ',command={' + ','.join('[=[' + part + ']=]' for part in provider) + '}}'
    configuration = '''return {
  api_version = 2,
  theme = "shade",
  runtime = { session = { persist = false }__ENGINE__ },
  client = { sidebar = { visible = false } },
  gui = {
    font = { family = "JetBrains Mono", size = 15 },
    window = { padding = { x = 0, y = 0 }, background_opacity = 1 },
    cursor = { blink = false },
  },
}
'''
    (output / 'gui.lua').write_text(configuration.replace('__ENGINE__', engine))
    native_capture.prepare_probe(output)
    shutil.copy2(Path(__file__), output / 'suggestion_driver.py')
    shutil.copy2(fixture, output / 'suggestion_engine_fixture.py')
    native_capture.script = suggestion_script
    result = dict(scope='Presented Cocoa suggestion panel captures. Pixel comparisons do not establish complete parity or comparative performance.',
                  state=options.state, query=options.query,
                  binary_sha256=dict(zig=native_capture.sha(options.zig_binary), qt=native_capture.sha(options.cpp_gui)), clients={})
    try:
        for kind in ['zig', 'qt']:
            result['clients'][kind] = native_capture.capture(kind, options.zig_binary.resolve(), options.cpp_gui.resolve(), output, options)
            observation = json.loads((output / kind / 'window.png.observation.json').read_text())
            if not observation['app_active'] or not observation['window_key'] or observation['presented_time'] <= observation['last_input_time']:
                raise RuntimeError(f'{kind}: capture did not follow the final active input geometry')
            if (output / 'suggestion-ran').exists():
                raise RuntimeError('The preview command executed during capture')
            print('Captured', kind, flush=True)
        result['comparison'] = native_capture.compare(output)
    finally:
        names = ['suggestion_driver.py', 'suggestion_engine_fixture.py', 'capture_driver.py', 'history_actions.m', 'history_capture.m', 'gui_view.h', 'gui.lua']
        result['source_sha256'] = {name: native_capture.sha(output / name) for name in names}
        (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result['comparison']), flush=True)


if __name__ == '__main__':
    main()
