import argparse
import datetime
import hashlib
import itertools
import json
from pathlib import Path
import random
import shutil
import struct
import subprocess

from check_history_card import pack_text, protocol
from check_notification_center import run
from check_text_fit import unicode_facade


reference = r'''
const std = @import("std");
const io = @import("protocol.zig");
const Field = @import("textfield").Type(512);
fn frame(field: *Field, operation: u8) !void {
    const width = try io.read(u16);
    const first = try io.read(u16);
    const last = try io.read(u16);
    const flags = try io.read(u8);
    const extend = flags & 1 != 0;
    const value = try io.readText();
    defer std.heap.page_allocator.free(value);
    var changed = false;
    switch (operation) {
        0 => field.setText(value),
        1 => changed = field.selectRange(.{ first, last }),
        2 => changed = field.replace(.{ first, last }, value),
        3 => field.insert(value),
        4 => field.backspace(),
        5 => field.delete(),
        6 => field.moveLeft(extend),
        7 => field.moveRight(extend),
        8 => field.home(extend),
        9 => field.end(extend),
        10 => field.moveWordLeft(extend),
        11 => field.moveWordRight(extend),
        12 => field.selectAll(),
        13 => field.clearSelection(),
        14 => {},
        else => unreachable,
    }
    var display = Field.init(field.text());
    _ = display.selectRange(.{ @intCast(field.anchor), @intCast(field.head) });
    const painted = if (flags & 2 != 0) &display else field;
    const view = painted.view(width);
    try io.write(@as(u8, @intFromBool(changed)));
    try io.writeText(field.text());
    try io.write(@as(u16, @intCast(field.head)));
    try io.write(@as(u16, @intCast(field.anchor)));
    try io.write(@as(u16, @intCast(painted.scroll)));
    try io.writeText(field.selected());
    try io.writeText(view.text);
    try io.write(view.cursor);
    try io.write(@as(u8, @intFromBool(view.selection != null)));
    try io.write(if (view.selection) |selection| selection[0] else @as(u16, 0));
    try io.write(if (view.selection) |selection| selection[1] else @as(u16, 0));
    try io.write(@as(u8, @intFromBool(view.clipped_left)));
    try io.write(@as(u8, @intFromBool(view.clipped_right)));
}
pub fn main() !void {
    var field: Field = .{};
    while (true) {
        const operation = io.operation();
        if (operation < 0) return;
        try frame(&field, @intCast(operation));
    }
}
'''


def prepare(repository, build, output):
    sources = ['lib/textfield/GenericField.zig', 'lib/cellgrid/GraphemeIterator.zig', 'lib/cellgrid/Cluster.zig', 'lib/cellgrid/text.zig']
    for name in sources:
        shutil.copy2(repository / name, output / Path(name).name)
    (output / 'unicode.zig').write_text(unicode_facade)
    (output / 'cellgrid.zig').write_text('pub const GraphemeIterator = @import("GraphemeIterator.zig");\npub const text = @import("text.zig");\n')
    (output / 'protocol.zig').write_text(protocol)
    (output / 'facades.zig').write_text('pub const Rect = struct { x:f32=0, y:f32=0, width:f32=0, height:f32=0 };\n')
    (output / 'probe.zig').write_text(reference)
    library = next(line.split('=', 1)[1] for line in (build / 'CMakeCache.txt').read_text().splitlines() if line.startswith('GHOSTTY_VT_LIBRARY:FILEPATH='))
    command = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', '-lc++', library,
               '--dep', 'textfield', '-Mroot=' + str(output / 'probe.zig'),
               '--dep', 'cellgrid', '-Mtextfield=' + str(output / 'GenericField.zig'),
               '--dep', 'unicode', '-Mcellgrid=' + str(output / 'cellgrid.zig'),
               '-Municode=' + str(output / 'unicode.zig'), '-femit-bin=' + str(output / 'original')]
    with (output / 'reference-build.log').open('w') as log:
        subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
    return command, sources


def frame(operation, width=32, first=0, last=0, extend=False, text=b'', snapshot=True):
    flags = int(extend) | (int(snapshot) << 1)
    return struct.pack('<B3HB', operation, width, first, last, flags) + pack_text(text)


def fixtures():
    values = ['', 'hello world', ' one\ttwo three ', 'a' * 128, 'x' * 512, 'árbol 中文 👩\u200d💻 e\u0301', '🇪🇸 test 🇯🇵', 'αβγ\tтест', 'x\u0301\u0327\u0300' * 16]
    for value, width in itertools.product(values, [0, 1, 2, 3, 8, 16, 32, 80, 65535]):
        encoded = value.encode()
        yield frame(0, width, text=encoded)
        yield frame(12, width)
        yield frame(6, width)
        for _ in range(6):
            yield frame(7, width, extend=True)
        yield frame(4, width)
        yield frame(3, width, text='🧵'.encode())
        yield frame(8, width)
        for _ in range(6):
            yield frame(5, width)
        yield frame(10, width)
        yield frame(11, width, extend=True)
        yield frame(9, width, extend=True)
        yield frame(13, width)
        yield frame(1, width, first=65535)
        yield frame(2, width, first=1, last=65535, text=b'rejected')
        yield frame(2, width, text=b'\xff')
        yield frame(2, width, text=b'\xc0\x80')
        yield frame(2, width, text=b'\xed\xa0\x80')
        yield frame(2, width, text=b'\xf4\x90\x80\x80')
        yield frame(12, width)
        yield frame(3, width, text=b'z' * 513)
        yield frame(3, width, text=b'replacement')
    generator = random.Random(0xED1702)
    inserts = ['a', ' word ', '中', '👩\u200d💻', 'e\u0301', 'á', '🇪🇸', '', '\t']
    for _ in range(1600):
        value = ''.join(generator.choices(inserts, k=generator.randrange(20))).encode()
        yield frame(0, generator.randrange(1, 65), text=value)
        for _ in range(64):
            operation = generator.randrange(3, 15)
            yield frame(operation, generator.choice([1, 2, 8, 16, 32, 64]), extend=generator.choice([True, False]), text=generator.choice(inserts).encode() if operation == 3 else b'')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build-dir', required=True, type=Path)
    parser.add_argument('--output-dir', required=True, type=Path)
    options = parser.parse_args()
    repository = Path(__file__).resolve().parents[3]
    build = options.build_dir.resolve()
    output = options.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    command, originals = prepare(repository, build, output)
    cases = list(fixtures())
    payload = b''.join(cases)
    (output / 'input.bin').write_bytes(payload)
    expected = run(output / 'original', payload, output, 'original')
    actual = run(build / 'gui-editor-probe', payload, output, 'cpp')
    if actual != expected:
        offset = next((index for index, (old, new) in enumerate(zip(expected, actual)) if old != new), min(len(expected), len(actual)))
        raise RuntimeError(f'Editor mismatch at byte {offset}: original={len(expected)} cpp={len(actual)}')
    sources = [repository / name for name in originals]
    sources.extend([Path(__file__), Path(__file__).with_name('editor_probe.cpp'), repository / 'services/gui-cpp/text/bounded_editor.hpp', repository / 'services/gui-cpp/text/editor_view.hpp'])
    result = dict(recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), records=len(cases),
                  reference_command=command, input_sha256=hashlib.sha256(payload).hexdigest(), output_bytes=len(actual), output_sha256=hashlib.sha256(actual).hexdigest(),
                  source_sha256={str(p.relative_to(repository)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
                  scope='Unmodified original bounded editor, grapheme iterator and column measurement. Valid in-capacity initialization; editing, movement, selection and atomic rejection. Each display uses a fresh copy, matching EditorDisplay.capture in the actual GUI. Persistent editor scrolling, Qt events, IME composition, rendering and performance are outside this oracle.')
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print('Matched', len(cases), 'editor transitions:', result['output_sha256'])


if __name__ == '__main__':
    main()
