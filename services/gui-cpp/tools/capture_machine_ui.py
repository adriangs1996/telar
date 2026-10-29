import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import sys

from PIL import Image, ImageChops

import capture_history as native
import capture_palette as palette


def main():
    parser = argparse.ArgumentParser(description='Compare presented native machine picker and name prompts with the Zig GUI')
    parser.add_argument('zig_binary', type=Path)
    parser.add_argument('cpp_gui', type=Path)
    parser.add_argument('output_directory', type=Path)
    parser.add_argument('--scene', choices=['picker', 'add-label', 'add-destination', 'rename'], default='picker')
    parser.add_argument('--query')
    parser.add_argument('--viewport', type=int, nargs=2, default=[1180, 720])
    parser.add_argument('--region', type=int, nargs=4, metavar=('LEFT', 'TOP', 'RIGHT', 'BOTTOM'))
    parser.add_argument('--capture-timeout', type=float, default=35)
    options = parser.parse_args()
    options.query = options.query if options.query is not None else ':Build' if options.scene == 'rename' else ':'
    options.selected_row = 0
    options.empty_history = True
    options.history_response = 'normal'
    if options.scene != 'picker' and options.query != (':Build' if options.scene == 'rename' else ':'):
        parser.error('Prompt scenes require their complete fixture query')
    if options.region is not None and not (0 <= options.region[0] < options.region[2] <= options.viewport[0] and 0 <= options.region[1] < options.region[3] <= options.viewport[1]):
        parser.error('Region must be inside the logical viewport')

    for name in ['SSH_CONNECTION', 'SSH_TTY']:
        os.environ.pop(name, None)

    output = options.output_directory.resolve()
    output.mkdir(parents=True, exist_ok=False)
    (output / 'work').mkdir()
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
    shutil.copy2(__file__, output / 'machine_ui_driver.py')
    shutil.copy2(Path(palette.__file__), output / 'palette_driver.py')
    profiles = dict(version=1, local_label='Local', machines=[
        dict(id='m-000000000001', label='Build', destination='dev@build', enabled=False),
        dict(id='m-000000000002', label='Other', destination='node', enabled=False),
    ])

    def script(directory, settings):
        configuration = directory / 'config/telar'
        configuration.mkdir(parents=True)
        profile_path = configuration / 'machines.json'
        profile_path.write_text(json.dumps(profiles) + '\n')
        profile_path.chmod(0o600)
        palette.palette_script(directory, settings)
        if options.scene == 'picker':
            return

        path = directory / 'actions.json'
        steps = json.loads(path.read_text())
        insertion = next(index for index, step in enumerate(steps) if step.get('resize') == [settings.viewport[0] + 1, settings.viewport[1]])
        input_ticks = 10
        edits = []
        if options.scene == 'rename':
            edits.extend([dict(key='\x12', unmodified='r', code=15, ctrl=True), *([{}] * input_ticks)])
        else:
            add_row = len(profiles['machines']) + 1
            for _ in range(add_row):
                edits.extend([dict(key='\uf701', code=125), {}, {}])
            edits.extend([dict(key='\r', code=36), *([{}] * input_ticks)])
            if options.scene == 'add-destination':
                edits.extend([dict(text='Newbox'), dict(key='\r', code=36), *([{}] * input_ticks)])
        steps[insertion:insertion] = edits
        path.write_text(json.dumps(steps) + '\n')

    window_actions = []
    original_prepare = native.float_owned_windows

    def prepare_owned(process, floated):
        original_prepare(process, floated)
        if not shutil.which('aerospace'):
            return

        listing = subprocess.run(['aerospace', 'list-windows', '--monitor', 'all', '--pid', str(process.pid), '--json'], capture_output=True, text=True, timeout=5, check=True)
        for row in json.loads(listing.stdout):
            identity = str(row['window-id'])
            if any(action['window_id'] == identity for action in window_actions):
                continue
            command = ['aerospace', 'focus', '--window-id', identity]
            focused = subprocess.run(command, capture_output=True, text=True, timeout=5)
            window_actions.append(dict(command=command, window_id=identity, owned_gui_pid=process.pid, exit_code=focused.returncode))
            if focused.returncode != 0:
                raise RuntimeError('Cannot prepare the owned capture window focus')

    native.script = script
    native.float_owned_windows = prepare_owned
    binaries = dict(zig=options.zig_binary.resolve(), qt=options.cpp_gui.resolve())
    record = dict(recorded_at=datetime.now(timezone.utc).isoformat(), command=sys.argv, scene=options.scene, query=options.query, clients={},
                  scope='Presented Cocoa/Metal machine UI with disabled saved profiles. No live SSH or other theme/density acceptance.',
                  binary_sha256={name: native.sha(path) for name, path in binaries.items()})
    with tempfile.TemporaryDirectory(prefix='telar-machine-capture-') as temporary:
        link = Path(temporary) / 'case'
        link.symlink_to(output, target_is_directory=True)
        native.prepare_probe(link)
        try:
            for kind in ['zig', 'qt']:
                record['clients'][kind] = native.capture(kind, binaries['zig'], binaries['qt'], link, options)
                observation = json.loads((link / kind / 'window.png.observation.json').read_text())
                if not observation['app_active'] or not observation['window_key'] or observation['presented_time'] <= observation['last_input_time']:
                    raise RuntimeError(f'{kind}: capture did not follow the final active input geometry')
                print('Captured', kind, flush=True)
            record['full_window'] = native.compare(link)
            with Image.open(link / 'zig/window.png') as original, Image.open(link / 'qt/window.png') as candidate:
                density = original.width / options.viewport[0]
                region = options.region or [0, 0, *options.viewport]
                bounds = [round(value * density) for value in region]
                left_image = original.crop(bounds).convert('RGBA')
                right_image = candidate.crop(bounds).convert('RGBA')
                delta = ImageChops.difference(left_image, right_image)
                coverage = delta.getchannel('R')
                for channel in ['G', 'B', 'A']:
                    coverage = ImageChops.lighter(coverage, delta.getchannel(channel))
                record['modal_region'] = dict(bounds=bounds, logical_bounds=region, compared_pixels=left_image.width * left_image.height,
                                            different_pixels=left_image.width * left_image.height - coverage.histogram()[0], difference_bounds=coverage.getbbox())
                left_image.save(link / 'zig/modal.png')
                right_image.save(link / 'qt/modal.png')
                delta.convert('RGB').save(link / 'modal-difference.png')
        finally:
            record['window_actions'] = window_actions
            record['source_sha256'] = {str(path.relative_to(output)): native.sha(path) for path in output.rglob('*') if path.is_file() and path.suffix in ['.py', '.m', '.h', '.lua', '.json'] and path.name != 'result.json'}
            (output / 'result.json').write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(record.get('modal_region')), flush=True)


if __name__ == '__main__':
    main()
