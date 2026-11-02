import argparse
import datetime
import hashlib
import itertools
import json
from pathlib import Path
import random
import re
import shutil
import struct
import subprocess

from check_text_fit import unicode_facade


canvas_facade = r'''
const std = @import("std");
const data = @import("model");
const gfx = @import("gfx");
const text = @import("text.zig");
const Label = @import("Label.zig");
const Canvas = @This();

pub const Entry = struct {
    bytes: [128]u8 = undefined,
    len: usize = 0,
    bounds: gfx.Rect = .{.x = 0, .y = 0, .width = 0, .height = 0},
    color: data.Color = .subtext0,
    bold: bool = false,
};
pub const Chrome = struct {
    ratio: f32,
    pub fn px(self: Chrome, value: f32) f32 { return value * self.ratio; }
};
chrome: Chrome,
cell_width: f32,
theme: struct { palette: data.Palette = .{} } = .{},
chip: gfx.Rect = .{.x = 0, .y = 0, .width = 0, .height = 0},
radius: f32 = 0,
entries: [18]Entry = @splat(.{}),
count: usize = 0,

pub fn measure(self: *Canvas, label: Label) !f32 {
    return @as(f32, @floatFromInt(text.measure(label.text))) * self.cell_width;
}
pub fn fillRoundedAt(self: *Canvas, bounds: gfx.Rect, fill: anytype) !void {
    self.chip = bounds;
    self.radius = fill.radius;
}
pub fn textAt(self: *Canvas, bounds: gfx.Rect, label: Label) !f32 {
    const entry = &self.entries[self.count];
    @memcpy(entry.bytes[0..label.text.len], label.text);
    entry.len = label.text.len;
    entry.bounds = bounds;
    entry.color = label.color;
    entry.bold = label.bold;
    self.count += 1;
    return self.measure(label);
}
'''

zig_probe = r'''
const std = @import("std");
const keyinput = @import("keyinput");
const client = @import("telar-client");
const Canvas = @import("Canvas.zig");
const ModeBar = @import("ModeBar.zig");
extern "c" fn getchar() c_int;
extern "c" fn putchar(c_int) c_int;

const Chord = extern struct { kind: u32, character: u32, modifiers: u32 };
const Request = extern struct { dimensions: [6]f32, mode: u32, mask: u32, chords: [8]Chord };
LABELS_DECLARATION

fn writeBytes(bytes: []const u8) !void {
    for (bytes) |byte| {
        if (putchar(byte) < 0) return error.WriteFailed;
    }
}
fn writeText(text: []const u8) !void {
    const length: u32 = @intCast(text.len);
    try writeBytes(std.mem.asBytes(&length));
    try writeBytes(text);
}
fn key(chord_record: Chord) !keyinput.Key {
    const specials = [_]keyinput.Key.Code{.up, .down, .left, .right, .home, .end, .delete, .page_up, .page_down, .enter, .escape, .backspace, .tab, .back_tab};
    var storage: [4]u8 = undefined;
    const code: keyinput.Key.Code = if (chord_record.kind == 0) .{.char = keyinput.Char.init(storage[0..try std.unicode.utf8Encode(@intCast(chord_record.character), &storage)])} else specials[chord_record.kind - 1];
    return .{.code = code, .mods = .{.ctrl = chord_record.modifiers & 1 != 0, .alt = chord_record.modifiers & 2 != 0, .shift = chord_record.modifiers & 4 != 0, .super = chord_record.modifiers & 8 != 0}};
}
fn record(request: Request) !void {
    var hints: client.Hints = .{};
    for (request.chords, 0..) |chord, index| {
        if (request.mask & (@as(u32, 1) << @intCast(index)) == 0) continue;
        hints.append(.{.key = try key(chord), .label = labels[index]});
    }
    var canvas: Canvas = .{.chrome = .{.ratio = request.dimensions[4]}, .cell_width = request.dimensions[5]};
    const mode: client.Mode = switch (request.mode) {0 => .normal, 1 => .{.prefix = hints}, 2 => .copy, else => return error.InvalidMode};
    try (ModeBar{.mode = mode, .area = .{.x = request.dimensions[0], .y = request.dimensions[1], .width = request.dimensions[2], .height = request.dimensions[3]}}).draw(&canvas);
    const count: u32 = @intCast(canvas.count);
    try writeBytes(std.mem.asBytes(&count));
    const chip = [_]f32{canvas.chip.x, canvas.chip.y, canvas.chip.width, canvas.chip.height, canvas.radius};
    try writeBytes(std.mem.asBytes(&chip));
    for (canvas.entries[0..canvas.count]) |entry| {
        try writeText(entry.bytes[0..entry.len]);
        const bounds = [_]f32{entry.bounds.x, entry.bounds.y, entry.bounds.width, entry.bounds.height};
        try writeBytes(std.mem.asBytes(&bounds));
        try writeText(@tagName(entry.color));
        const bold: u8 = @intFromBool(entry.bold);
        try writeBytes(std.mem.asBytes(&bold));
    }
}
pub fn main() !void {
    while (true) {
        var bytes: [@sizeOf(Request)]u8 = undefined;
        const first = getchar();
        if (first < 0) return;
        bytes[0] = @intCast(first);
        for (bytes[1..]) |*byte| {
            const next = getchar();
            if (next < 0) return error.TruncatedInput;
            byte.* = @intCast(next);
        }
        try record(std.mem.bytesToValue(Request, &bytes));
    }
}
'''


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def requests():
    default_keys = [(0, ord(value), 0) for value in '%"cC,.x[']

    def encode(mode, width, height=26, ratio=1, cell_width=9, mask=255, keys=default_keys, origin=(8, 974)):
        return struct.pack('<6fII', *origin, width, height, ratio, cell_width, mode, mask) + b''.join(struct.pack('<3I', *key) for key in keys)

    for mode, width, ratio, height in itertools.product(range(3), [0, 1, 8, 40, 54, 72, 100, 152, 164, 200, 320, 640, 1200, 2400], [.5, .75, 1, 1.25, 1.5, 2], [0, 10, 26, 52]):
        yield encode(mode, width, height, ratio)

    for mask in range(256):
        yield encode(1, 2400, mask=mask)

    for kind, modifiers in itertools.product(range(15), range(16)):
        keys = [(kind, ord('a'), modifiers)] * 8
        yield encode(1, 2400, keys=keys)

    for character in [' ', '\x00', 'ñ', '中', '😀', '́']:
        for modifiers in range(16):
            yield encode(1, 2400, keys=[(0, ord(character), modifiers)] * 8)

    rng = random.Random(0xB4A)
    for _ in range(4096):
        yield encode(rng.randrange(3), rng.uniform(0, 2400), rng.uniform(1, 70), rng.uniform(.5, 2.5), rng.uniform(1, 48), rng.randrange(256), origin=(rng.uniform(-40, 40), rng.uniform(-40, 1200)))


def prepare_reference(root, build, output):
    for name in ['ModeBar.zig', 'HintPen.zig']:
        shutil.copy2(root / 'src/gui/widgets' / name, output / name)
    for name in ['GraphemeIterator.zig', 'Cluster.zig', 'text.zig']:
        shutil.copy2(root / 'lib/cellgrid' / name, output / name)
    for name in ['Hints.zig', 'hints_support.zig']:
        shutil.copy2(root / 'src/client/input' / name, output / name)
    (output / 'Canvas.zig').write_text(canvas_facade)
    (output / 'Label.zig').write_text('text: []const u8,\ncolor: @import("model").Color = .subtext0,\nbold: bool = false,\n')
    (output / 'model.zig').write_text('pub const Color = enum {accent, subtext0, surface_dim};\npub const Palette = struct {accent: Color = .accent, subtext0: Color = .subtext0, surface_dim: Color = .surface_dim};\n')
    (output / 'client.zig').write_text('pub const Hints = @import("Hints.zig");\npub const Mode = @import("hints_support.zig").Mode;\n')
    (output / 'unicode.zig').write_text(unicode_facade)
    presentation = (root / 'src/gui/window_presentation.zig').read_text()
    labels = re.search(r'const labels = \[_\]\[\]const u8\{.*?\n    \};', presentation, re.S)
    if labels is None:
        raise RuntimeError('The original mode hint labels were not found')
    (output / 'probe.zig').write_text(zig_probe.replace('LABELS_DECLARATION', labels.group()))
    cache = (build / 'CMakeCache.txt').read_text().splitlines()
    unicode_library = next(line.split('=', 1)[1] for line in cache if line.startswith('GHOSTTY_VT_LIBRARY:FILEPATH='))
    return [
        'zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', '-lc++', unicode_library,
        '--dep', 'keyinput', '--dep', 'model', '--dep', 'gfx', '--dep', 'telar-client', '--dep', 'unicode', f'-Mroot={output / "probe.zig"}',
        f'-Mkeyinput={root / "lib/keyinput/root.zig"}', f'-Mmodel={output / "model.zig"}', f'-Mgfx={root / "lib/gfx/root.zig"}',
        '--dep', 'keyinput', f'-Mtelar-client={output / "client.zig"}', f'-Municode={output / "unicode.zig"}', f'-femit-bin={output / "zig"}',
    ]


def run(root, build, output):
    output.mkdir(parents=True, exist_ok=True)
    command = prepare_reference(root, build, output)
    subprocess.run(command, check=True)
    cases = list(requests())
    payload = b''.join(cases)
    (output / 'input.bin').write_bytes(payload)
    results = {}
    cpp = build / 'gui-mode-bar-probe'
    for name, executable in [('zig', output / 'zig'), ('cpp', cpp)]:
        result = subprocess.run([str(executable)], input=payload, capture_output=True, check=True)
        (output / f'{name}.bin').write_bytes(result.stdout)
        results[name] = result.stdout
    if results['zig'] != results['cpp']:
        mismatch = next((i for i, pair in enumerate(zip(results['zig'], results['cpp'])) if pair[0] != pair[1]), min(map(len, results.values())))
        raise RuntimeError(f'Mode bar differs at output byte {mismatch}; inspect {output}')
    sources = [
        'src/gui/widgets/ModeBar.zig', 'src/gui/widgets/HintPen.zig', 'src/gui/window_presentation.zig',
        'src/client/input/Hints.zig', 'src/client/input/hints_support.zig', 'lib/keyinput/Key.zig', 'lib/keyinput/Char.zig', 'lib/keyinput/Mods.zig',
        'lib/cellgrid/GraphemeIterator.zig', 'lib/cellgrid/text.zig', 'lib/cellgrid/Cluster.zig',
        'services/gui-cpp/presentation/mode_bar_layout.hpp', 'services/gui-cpp/presentation/mode_hints.hpp', 'services/gui-cpp/presentation/mode_key_label.hpp', 'services/gui-cpp/text/cell_text_measure.hpp',
        'services/gui-cpp/tools/mode_bar_probe.cpp', 'services/gui-cpp/tools/check_mode_bar.py', 'services/gui-cpp/tools/check_text_fit.py',
        'services/gui-cpp/input/key_character.hpp', 'services/gui-cpp/qt/key_adapter.hpp',
    ]
    report = {
        'recorded_at': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'requests': len(cases),
        'scope': 'Original ModeBar.draw call geometry, titles, formatted keys, named ink roles, bold flags and whole-token fitting. No rasterization, font fallback, real router hint selection or window parity claim.',
        'reference_adaptation': 'ModeBar, HintPen, Hints and cell measurement source bytes are unchanged. Canvas records calls and measures original graphemes at the supplied cell width. Palette values are role names; Unicode forwards to the pinned Ghostty grapheme API. Hint lists use the eight original fixed labels.',
        'input_sha256': sha(output / 'input.bin'), 'output_sha256': sha(output / 'cpp.bin'),
        'cpp_binary_sha256': sha(cpp), 'zig_binary_sha256': sha(output / 'zig'),
        'source_sha256': {name: sha(root / name) for name in sources},
        'generated_reference_sha256': {path.name: sha(path) for path in sorted(output.glob('*.zig'))}, 'zig_command': command,
    }
    (output / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build-dir', type=Path, default=Path('services/gui-cpp/out'))
    parser.add_argument('--output-dir', type=Path, required=True)
    options = parser.parse_args()
    run(Path(__file__).resolve().parents[3], options.build_dir.resolve(), options.output_dir.resolve())


if __name__ == '__main__':
    main()
