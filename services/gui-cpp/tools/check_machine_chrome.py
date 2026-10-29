import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import random
import shutil
import struct
import subprocess


def sha(data):
    return hashlib.sha256(data).hexdigest()


def fixtures():
    cases = []
    for segment in [False, True]:
        for ratio in [0.5, 0.75, 1, 1.25, 1.5, 2, 3]:
            for width in [0, 1, 7, 17, 20, 38.5, 50, 83, 120, 150, 267, 600, 4096]:
                for count in [1, 2, 3, 17]:
                    cases.append(dict(segment=segment, ratio=ratio, area=[8.25, 12.5, width * ratio, 17 * ratio], count=count, active=count - 1, attention=(1 << count) - 1, more=23.5 * ratio, fold=12.5 * ratio, advances=[(23.25 + index * 13.75) * ratio for index in range(17)]))
    randomizer = random.Random(0xC470)
    for _ in range(4000):
        count = randomizer.randrange(1, 18)
        cases.append(dict(segment=bool(randomizer.randrange(2)), ratio=randomizer.choice([0.5, 0.75, 1, 1.125, 1.25, 1.5, 2, 3]), area=[randomizer.randrange(100) / 4, randomizer.randrange(100) / 4, randomizer.randrange(2500) / 4, randomizer.choice([1, 3, 7, 13, 17, 26, 51.5])], count=count, active=randomizer.randrange(count), attention=randomizer.randrange(1 << count), more=randomizer.randrange(200) / 4, fold=randomizer.randrange(200) / 4, advances=[randomizer.randrange(2000) / 4 for _ in range(17)]))
    return cases


def prepare(repository, output):
    originals = []
    for name in ['MachineSwitcher', 'MachineSegment', 'PixelButton', 'AttentionDot', 'Label', 'label_face', 'label_size', 'BandPlacement', 'action', 'bar_tone']:
        relative = 'src/gui/widgets/' + name + '.zig'
        shutil.copy2(repository / relative, output / (name + '.zig'))
        originals.append(relative)
    (output / 'gfx').mkdir()
    for name in ['Layout', 'Item', 'Rect', 'Insets', 'length', 'alignment']:
        relative = 'lib/gfx/' + name + '.zig'
        shutil.copy2(repository / relative, output / 'gfx' / (name + '.zig'))
        originals.append(relative)
    (output / 'gfx/gfx.zig').write_text('pub const Rect = @import("Rect.zig");\npub const Layout = @import("Layout.zig");\npub const Item = @import("Item.zig");\npub const alignment = @import("alignment.zig");\n')
    for path in (Path(__file__).parent / 'reference_machine_chrome').glob('*.zig'):
        shutil.copy2(path, output / path.name)
    (output / 'core.zig').write_text('pub const PaneId = enum(u64) { invalid, _ };\n')
    (output / 'cellgrid.zig').write_text('pub const Color = struct { pub const default: @This() = .{}; };\n')
    (output / 'model.zig').write_text('''const cellgrid = @import("cellgrid");
pub const bar_values = struct {
    pub const PaletteColor = enum { accent };
    pub const Color = union(enum) { value: cellgrid.Color, palette: PaletteColor };
};
pub const color_name = struct {
    pub fn parse(_: []const u8) ?bar_values.Color { return null; }
};
''')
    return originals


def build_command(output):
    return ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', '--dep', 'gfx', '--dep', 'cellgrid', '--dep', 'model', '--dep', 'telar-client', '--dep', 'telar-core', '-Mroot=' + str(output / 'probe.zig'), '-Mgfx=' + str(output / 'gfx/gfx.zig'), '-Mcellgrid=' + str(output / 'cellgrid.zig'), '--dep', 'cellgrid', '-Mmodel=' + str(output / 'model.zig'), '-Mtelar-client=' + str(output / 'client.zig'), '-Mtelar-core=' + str(output / 'core.zig'), '-femit-bin=' + str(output / 'original-chrome')]


def frames(data):
    offset = 0
    result = []
    while offset < len(data):
        start = offset
        preferred = struct.unpack_from('<f', data, offset)[0]
        offset += 4
        events = []
        while data[offset] != 0:
            event = data[offset]
            area = struct.unpack_from('<4f', data, offset + 1)
            offset += 17
            target = data[offset] if event == 3 else None
            offset += event == 3
            events.append([event, area, target])
        offset += 1
        result.append(dict(bytes=data[start:offset].hex(), preferred=preferred, events=events))
    return result


def main():
    parser = argparse.ArgumentParser(description='Replay unchanged original machine widgets and gfx layout with a recording canvas')
    parser.add_argument('--build-dir', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    options = parser.parse_args()
    repository = Path(__file__).resolve().parents[3]
    output = options.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    originals = prepare(repository, output)
    command = build_command(output)
    with (output / 'reference-build.log').open('w') as log:
        subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
    cases = fixtures()
    requests = b''.join(b'\0' + struct.pack('<B5fBBI19f', case['segment'], case['ratio'], *case['area'], case['count'], case['active'], case['attention'], case['more'], case['fold'], *case['advances']) for case in cases)
    (output / 'cases.json').write_text(json.dumps(cases) + '\n')
    (output / 'requests.bin').write_bytes(requests)
    results = {}
    for kind, binary in [('original', output / 'original-chrome'), ('cpp', options.build_dir.resolve() / 'gui-machine-chrome-probe')]:
        result = subprocess.run([str(binary)], input=requests, capture_output=True, check=True)
        (output / (kind + '.bin')).write_bytes(result.stdout)
        (output / (kind + '.stderr')).write_bytes(result.stderr)
        results[kind] = result.stdout
    equal = results['original'] == results['cpp']
    decoded = {kind:frames(data) for kind,data in results.items()}
    assert all(len(values) == len(cases) for values in decoded.values())
    differences = [dict(index=index, case=cases[index], original=left, cpp=right) for index,(left,right) in enumerate(zip(decoded['original'], decoded['cpp'])) if left != right]
    (output / 'differences.json').write_text(json.dumps(differences, indent=2) + '\n')
    sources = [*originals, 'services/gui-cpp/presentation/machine_chrome_geometry.hpp', 'services/gui-cpp/tools/machine_chrome_probe.cpp', str(Path(__file__).relative_to(repository)), *[str(path.relative_to(repository)) for path in (Path(__file__).parent / 'reference_machine_chrome').glob('*.zig')]]
    result = dict(recorded_at=datetime.now(timezone.utc).isoformat(), cases=len(cases), differences=len(differences), bytes={kind:len(data) for kind,data in results.items()}, equal=equal, input_sha256=sha(requests), output_sha256={kind:sha(data) for kind,data in results.items()}, source_sha256={name:sha((repository/name).read_bytes()) for name in sources}, command=command, scope='Unchanged MachineSwitcher, MachineSegment, PixelButton, AttentionDot and gfx Layout, positive control heights. Canvas records requested paint rectangles and hit bands; machine, palette and text measurement facades are controlled input. Font rasterization, colors, native interaction and visual acceptance are separate gates.')
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))
    assert equal


if __name__ == '__main__':
    main()
