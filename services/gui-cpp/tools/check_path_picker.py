import argparse
from collections import Counter
import hashlib
import itertools
import json
from pathlib import Path
import random
import shutil
import struct
import subprocess

from check_history_card import protocol
from check_notification_center import function_source
from check_text_fit import unicode_facade


reference = r'''
const std = @import("std");
const io = @import("protocol.zig");
const cellgrid = @import("cellgrid");
const PathLabel = @import("PathLabel.zig");
const PathPickerPlacement = struct { area: cellgrid.Rect, flipped: bool };
const max_rows = 10;
const max_width = 72;
const chrome_rows = 4;
const cursor_inset = 2;
const max_text_bytes = 20480;
const plain_bytes = "_-./+@%,:";
__FUNCTIONS__
fn quoteCase() !void {
    const word = try io.readText();
    var buffer: [max_text_bytes]u8 = undefined;
    const result = quote(word, &buffer);
    try io.write(@as(u8, if (result != null) 1 else 0));
    if (result) |text| try io.writeText(text);
}
fn joinCase() !void {
    const root = try io.readText();
    const relative = try io.readText();
    const anchor = try io.readText();
    var buffer: [5121]u8 = undefined;
    const joined = join(root, relative, &buffer) orelse return error.JoinFailed;
    try io.writeText(joined);
    const result = relativeTo(anchor, joined);
    try io.write(@as(u8, if (result != null) 1 else 0));
    if (result) |text| try io.writeText(text);
}
fn placementCase() !void {
    const x = try io.read(u16);
    const y = try io.read(u16);
    const width = try io.read(u16);
    const height = try io.read(u16);
    const host: cellgrid.Rect = .{ .x = x, .y = y, .w = width, .h = height };
    var cursor: ?cellgrid.Point = null;
    if (try io.read(u8) != 0) {
        const column = try io.read(u16);
        cursor = .{ .x = column, .y = try io.read(u16) };
    }
    const result = forPage(host, cursor, try io.read(u16));
    try io.write(result.area.x);
    try io.write(result.area.y);
    try io.write(result.area.w);
    try io.write(result.area.h);
    try io.write(@as(u8, if (result.flipped) 1 else 0));
}
fn labelCase() !void {
    const path = try io.readText();
    const width = try io.read(u16);
    const count = try io.read(u8);
    var positions: [64]u16 = undefined;
    for (positions[0..count]) |*position| position.* = try io.read(u16);
    var label: PathLabel = .{};
    label.layout(path, positions[0..count], width);
    try io.write(label.len);
    for (label.slice()) |run| {
        try io.write(@as(u8, @intFromEnum(run.tone)));
        try io.writeText(run.text);
    }
}
pub fn main() !void {
    while (true) {
        switch (io.operation()) {
            -1 => return,
            1 => try quoteCase(),
            2 => try joinCase(),
            3 => try placementCase(),
            4 => try labelCase(),
            else => return error.Operation,
        }
    }
}
'''


def text(value):
    encoded = value.encode() if isinstance(value, str) else value
    return struct.pack('<H', len(encoded)) + encoded


def fixtures():
    random_source = random.Random(0x50415448)
    words = ['plain.txt', '-option', "a b'c", '中/🧵.txt', '$HOME;exit', 'a\nb', '\\', 'a\t', '~name']
    words.extend("'" * size for size in [5118, 5119, 5120, 5121])
    words.extend(''.join(random_source.choices("abcXYZ -_'/$;`\\é中🧵", k=random_source.randrange(1, 160))) for _ in range(1600))
    for word in words:
        yield 'quote', b'\1' + text(word)
    for root, relative, anchor in itertools.product(['/', '/work', '/work/sub', '/worktree', '/outside', '/é/中'], ['file', 'nested/file', 'a b/', '-option'], ['/', '/work', '/work/sub', '/unrelated']):
        yield 'join', b'\2' + text(root) + text(relative) + text(anchor)
    for width, height, origin, count in itertools.product([1, 2, 3, 8, 20, 71, 72, 73, 100, 400], [1, 2, 4, 5, 6, 10, 14, 30, 80], [(0, 0), (3, 7)], [0, 1, 2, 9, 10, 11, 50]):
        x, y = origin
        points = [None, (x, y), (x + width // 2, y + height // 2), (x + width - 1, y + height - 1)]
        for point in points:
            cursor = b'\0' if point is None else b'\1' + struct.pack('<HH', *point)
            yield 'placement', b'\3' + struct.pack('<HHHH', x, y, width, height) + cursor + struct.pack('<H', count)
    paths = ['file.cpp', 'src/main.cpp', 'directory/', 'deep/directory/file.cpp', 'é/mañana.txt', '中/路径.txt', 'emoji/👩‍💻.txt', 'á/combiné.txt', 'a/' * 240 + 'final.txt', '////']
    for path, width in itertools.product(paths, range(81)):
        encoded = path.encode()
        positions = [[], [0], [len(encoded) - 1], list(range(min(len(encoded), 64))) ]
        for highlights in positions:
            packed = b''.join(struct.pack('<H', position) for position in highlights)
            yield 'label', b'\4' + text(encoded) + struct.pack('<HB', width, len(highlights)) + packed


def prepare(repository, build, output):
    for name in ['PathLabel.zig', 'PathLabelRun.zig']:
        shutil.copy2(repository / 'src/model/state' / name, output / name)
    source = (repository / 'src/client/input/path_picker.zig').read_text()
    placement = (repository / 'src/model/state/path_picker_placement.zig').read_text()
    functions = [function_source(source, name) for name in ['quote', 'isPlain', 'join', 'relativeTo']]
    functions.extend(function_source(placement, name) for name in ['forPage', 'place'])
    (output / 'probe.zig').write_text(reference.replace('__FUNCTIONS__', '\n'.join(functions)))
    (output / 'protocol.zig').write_text(protocol)
    (output / 'facades.zig').write_text('pub const Rect = struct { x: f32, y: f32, width: f32, height: f32 };\n')
    (output / 'core.zig').write_text('pub const max_path_query_bytes = 64;\n')
    (output / 'unicode.zig').write_text(unicode_facade)
    cache = (build / 'CMakeCache.txt').read_text().splitlines()
    unicode_library = next(line.split('=', 1)[1] for line in cache if line.startswith('GHOSTTY_VT_LIBRARY:FILEPATH='))
    command = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', '-lc++', unicode_library,
               '--dep', 'telar-core', '--dep', 'cellgrid', f'-Mroot={output / "probe.zig"}',
               f'-Mtelar-core={output / "core.zig"}', '--dep', 'unicode',
               f'-Mcellgrid={repository / "lib/cellgrid/root.zig"}', f'-Municode={output / "unicode.zig"}',
               f'-femit-bin={output / "original"}']
    with (output / 'reference-build.log').open('w') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    return command


def main():
    parser = argparse.ArgumentParser(description='Compare path quoting, placement and styled labels with unchanged original Zig procedures')
    parser.add_argument('--build-dir', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    options = parser.parse_args()
    repository = Path(__file__).resolve().parents[3]
    build = options.build_dir.resolve()
    output = options.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    command = prepare(repository, build, output)
    cases = list(fixtures())
    payload = b''.join(value for _, value in cases)
    (output / 'input.bin').write_bytes(payload)
    outputs = {}
    binaries = {'original': output / 'original', 'cpp': build / 'gui-path-picker-probe'}
    for name, binary in binaries.items():
        result = subprocess.run([str(binary)], input=payload, capture_output=True, check=True)
        (output / f'{name}-output.bin').write_bytes(result.stdout)
        (output / f'{name}-run.log').write_bytes(result.stderr)
        outputs[name] = result.stdout
    if outputs['cpp'] != outputs['original']:
        common = min(len(outputs['cpp']), len(outputs['original']))
        offset = next((index for index in range(common) if outputs['cpp'][index] != outputs['original'][index]), common)
        raise AssertionError(f'Path picker output differs at byte {offset}; evidence retained in {output}')
    sources = ['src/client/input/path_picker.zig', 'src/model/state/path_picker_placement.zig',
               'src/model/state/PathLabel.zig', 'src/model/state/PathLabelRun.zig',
               'services/gui-cpp/paths/insertion.hpp', 'services/gui-cpp/paths/label.hpp',
               'services/gui-cpp/presentation/path_picker_placement.hpp',
               'services/gui-cpp/tools/path_picker_probe.cpp', 'services/gui-cpp/tools/check_path_picker.py']
    result = dict(cases=len(cases), cases_by_kind=dict(Counter(kind for kind, _ in cases)),
                  input_sha256=hashlib.sha256(payload).hexdigest(), output_bytes=len(outputs['cpp']),
                  output_sha256=hashlib.sha256(outputs['cpp']).hexdigest(), reference_command=command,
                  binary_sha256={name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in binaries.items()},
                  source_sha256={name: hashlib.sha256((repository / name).read_bytes()).hexdigest() for name in sources},
                  scope='Unchanged original quote/isPlain/join/relativeTo, forPage/place and full PathLabel implementation. Both use Ghostty Unicode widths. Covers valid cursor positions, Unicode byte highlights and bounded quoting. Does not establish page-state equivalence, native pixels, complete behavior or comparative performance.')
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({key: result[key] for key in ['cases', 'cases_by_kind', 'output_bytes', 'output_sha256']}, indent=2))


if __name__ == '__main__':
    main()
