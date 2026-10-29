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
const State = @import("SuggestionState.zig");
const types = @import("facades.zig");
const Panel = @import("overlays/SuggestionPanel.zig");
const Canvas = @import("Canvas.zig");
fn transition(state: *State) !void {
    var received = false;
    switch (try io.read(u8)) {
        0 => state.* = .{},
        1 => state.begin(),
        2 => state.expect(try io.read(u64)),
        3 => state.invalidate(),
        4 => {
            const request_id = try io.read(u64);
            const status: @import("core.zig").SuggestionStatus = @enumFromInt(try io.read(u8));
            const text = try io.readText();
            defer std.heap.page_allocator.free(text);
            received = state.apply(.{ .request_id = request_id, .status = status, .text = text });
        },
        else => return error.InvalidTransition,
    }
    try io.write(@as(u8, @intFromBool(received)));
    try io.write(state.version());
    try io.write(state.pending_request);
    try io.write(@as(u8, @intFromEnum(state.phase)));
    try io.write(@as(u8, @intFromEnum(state.status)));
    try io.writeText(state.textSlice());
}
fn panel() !void {
    const bounds = try io.readRect();
    const footer = try io.readRect();
    const ratio = try io.read(f32);
    const body = try io.read(u16);
    const small = try io.read(u16);
    const width = try io.read(u16);
    const height = try io.read(u16);
    const phase = try io.read(u8);
    const status = try io.read(u8);
    const text = try io.readText();
    defer std.heap.page_allocator.free(text);
    const query = try io.readText();
    defer std.heap.page_allocator.free(query);
    var suggestion: State = .{ .phase = @enumFromInt(phase), .status = @enumFromInt(status), .text_len = @intCast(text.len) };
    @memcpy(suggestion.text[0..text.len], text);
    const projection: types.Projection = .{ .suggestion = suggestion, .prompt = .{ .query = query } };
    var canvas: Canvas = .{ .chrome = .{ .ratio = ratio, .body = body, .small = small }, .atlas = .{ .width = width, .height = height } };
    try (Panel{ .bounds = bounds, .footer_bounds = footer, .projection = &projection }).draw(&canvas);
    try io.write(@as(u8, 0));
}
pub fn main() !void {
    var state: State = .{};
    while (true) {
        switch (io.operation()) {
            -1 => return,
            1 => try transition(&state),
            2 => try panel(),
            else => return error.InvalidOperation,
        }
    }
}
'''


facades = r'''
pub const Rect = struct { x: f32 = 0, y: f32 = 0, width: f32 = 0, height: f32 = 0 };
pub const Color = enum(u8) { text, red, surface0, surface1 };
pub const Prompt = struct {
    query: []const u8, generation: u64 = 1,
    pub fn paletteQuery(self: @This()) []const u8 { return self.query; }
};
pub const Projection = struct { suggestion: @import("SuggestionState.zig"), prompt: ?Prompt };
pub const GuiConfig = struct { font: struct { size: f32 }, chrome: struct { scale: f32 } };
pub const Atlas = struct {
    width: u16, height: u16,
    pub fn cellWidth(self: @This(), _: u16) !u32 { return self.width; }
    pub fn lineHeight(self: @This(), _: u16) !u32 { return self.height; }
    pub fn ascender(_: @This(), _: u16) !i32 { return 0; }
};
pub const Quads = struct {
    pub fn items(_: @This()) []const u8 { return ""; }
    pub fn clipFrom(_: @This(), _: usize, _: Rect) void {}
};
pub const Label = struct {
    text: []const u8, face: enum(u8) { terminal, sans } = .terminal,
    size: @import("label_size.zig").Size = .terminal,
    bold: bool = false, color: Color, alpha: f32 = 1,
};
'''


canvas = r'''
const types = @import("facades.zig");
const io = @import("protocol.zig");
chrome: @import("ChromeMetrics.zig"),
atlas: types.Atlas,
quads: types.Quads = .{},
metrics: struct { cell_width: u32, cell_height: u16, baseline: f32, pixel_height: u16 } = .{ .cell_width = 1, .cell_height = 1, .baseline = 0, .pixel_height = 1 },
theme: struct { palette: struct { text: types.Color = .text, red: types.Color = .red, surface0: types.Color = .surface0, surface1: types.Color = .surface1 } = .{} } = .{},
pub fn textAt(_: *@This(), bounds: types.Rect, label: types.Label) !f32 {
    try io.write(@as(u8, 3));
    try io.writeRect(bounds);
    try io.writeText(label.text);
    try io.write(@as(u8, @intFromEnum(label.face)));
    try io.write(@as(u8, @intFromEnum(label.size)));
    try io.write(@as(u8, @intFromBool(label.bold)));
    try io.write(@as(u8, @intFromEnum(label.color)));
    try io.write(label.alpha);
    return 0;
}
pub fn fillAt(_: *@This(), bounds: types.Rect, color: types.Color) !void {
    try io.write(@as(u8, 1)); try io.writeRect(bounds); try io.write(@as(u8, @intFromEnum(color)));
}
pub fn fillRoundedAt(_: *@This(), bounds: types.Rect, fill: struct { color: types.Color, radius: f32 }) !void {
    try io.write(@as(u8, 2)); try io.writeRect(bounds); try io.write(@as(u8, @intFromEnum(fill.color))); try io.write(fill.radius);
}
'''


button = r'''
const types = @import("facades.zig");
const io = @import("protocol.zig");
bounds: types.Rect, text: []const u8, action: struct { prompt: enum { submit } },
generation: u64, namespace: u8, quiet: bool, enabled: bool,
pub fn draw(self: @This(), _: *@import("Canvas.zig")) !void {
    try io.write(@as(u8, 4)); try io.writeRect(self.bounds); try io.writeText(self.text);
    try io.write(@as(u8, @intFromBool(self.enabled))); try io.write(@as(u8, @intFromBool(self.quiet)));
}
'''


def text(value):
    encoded = value.encode() if isinstance(value, str) else value
    return struct.pack('<H', len(encoded)) + encoded


def fixtures():
    random_source = random.Random(0x53554747)
    yield 'state', b'\1\0'
    for request in [0, 1, 2, 2**64 - 1]:
        yield 'state', b'\1\1'
        yield 'state', b'\1\3'
        yield 'state', b'\1\2' + struct.pack('<Q', request)
        for reply in [0, request ^ 1, request, request]:
            for status in range(4):
                yield 'state', b'\1\4' + struct.pack('<QB', reply, status) + text('echo 🧵' if status == 0 else '')
    for _ in range(4000):
        operation = random_source.randrange(5)
        payload = b'\1' + bytes([operation])
        if operation == 2:
            payload += struct.pack('<Q', random_source.randrange(6))
        elif operation == 4:
            status = random_source.randrange(4)
            value = random_source.choice(['', 'pwd', 'x' * 1024, 'é中👩‍💻']) if status == 0 else ''
            payload += struct.pack('<QB', random_source.randrange(6), status) + text(value)
        yield 'state', payload
    dimensions = [(0, 0, 0, 0), (2, 3, 10, 12), (4, 7, 100, 90), (173.5, 155.25, 640, 180), (32, 86, 1280, 360)]
    values = ['', 'pwd', 'printf "é中👩‍💻 á"', 'x' * 1024, 'one\r\ntwo\nthree\rfour', 'a b ' * 100]
    for bounds, ratio, grid, phase, status, query in itertools.product(dimensions, [0.75, 1, 1.25, 2], [(1, 1), (8, 17), (16, 34)], range(4), range(4), ['', 'task']):
        x, y, width, height = bounds
        footer = (x, y + height, width, 40 * ratio)
        header = b'\2' + struct.pack('<8ff4H2B', *bounds, *footer, ratio, round(13 * ratio), round(11 * ratio), *grid, phase, status)
        for value in values if phase == 2 else ['']:
            yield 'panel', header + text(value) + text(query)


def prepare(repository, build, output):
    (output / 'overlays').mkdir()
    state_source = repository / 'src/model/state/SuggestionState.zig'
    (output / 'SuggestionState.zig').write_text(state_source.read_text().replace('@import("telar-core")', '@import("core.zig")'))
    shutil.copy2(repository / 'src/model/state/suggestion.zig', output / 'suggestion.zig')
    original_panel = repository / 'src/gui/widgets/overlays/SuggestionPanel.zig'
    source = original_panel.read_text().replace('@import("telar-client")', '@import("../facades.zig")').replace('@import("gfx")', '@import("../facades.zig")')
    (output / 'overlays/SuggestionPanel.zig').write_text(source)
    shutil.copy2(repository / 'src/gui/widgets/overlays/WrappedLines.zig', output / 'overlays/WrappedLines.zig')
    chrome = (repository / 'src/gui/widgets/ChromeMetrics.zig').read_text().replace('@import("telar-client")', '@import("facades.zig")')
    (output / 'ChromeMetrics.zig').write_text(chrome)
    shutil.copy2(repository / 'src/gui/widgets/label_size.zig', output / 'label_size.zig')
    inset = function_source((repository / 'src/gui/widgets/overlays/PaletteLayout.zig').read_text(), 'inset')
    (output / 'overlays/PaletteLayout.zig').write_text('const Rect = @import("../facades.zig").Rect;\n' + inset)
    core = 'pub const max_suggestion_bytes = 1024;\npub const SuggestionStatus = enum(u8) { ready, unavailable, timeout, failed };\npub const CommandSuggestion = struct { request_id: u64, status: SuggestionStatus, text: []const u8 };\npub fn raw(value: u64) u64 { return value; }\n'
    for name, value in [('probe.zig', reference), ('protocol.zig', protocol), ('facades.zig', facades), ('Canvas.zig', canvas), ('FormButton.zig', button), ('core.zig', core), ('unicode.zig', unicode_facade)]:
        (output / name).write_text(value)
    cache = (build / 'CMakeCache.txt').read_text().splitlines()
    library = next(line.split('=', 1)[1] for line in cache if line.startswith('GHOSTTY_VT_LIBRARY:FILEPATH='))
    command = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', '-lc++', library,
               '--dep', 'cellgrid', f'-Mroot={output / "probe.zig"}', '--dep', 'unicode',
               f'-Mcellgrid={repository / "lib/cellgrid/root.zig"}', f'-Municode={output / "unicode.zig"}',
               f'-femit-bin={output / "original"}']
    with (output / 'reference-build.log').open('w') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    return command


def main():
    parser = argparse.ArgumentParser(description='Compare suggestion transitions and panel drawing commands with the original Zig implementation')
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
    binaries = {'original': output / 'original', 'cpp': build / 'gui-suggestion-probe'}
    outputs = {}
    for name, binary in binaries.items():
        result = subprocess.run([str(binary)], input=payload, capture_output=True, check=True)
        (output / f'{name}-output.bin').write_bytes(result.stdout)
        (output / f'{name}-run.log').write_bytes(result.stderr)
        outputs[name] = result.stdout
    if outputs['cpp'] != outputs['original']:
        common = min(len(outputs['cpp']), len(outputs['original']))
        offset = next((index for index in range(common) if outputs['cpp'][index] != outputs['original'][index]), common)
        raise AssertionError(f'Suggestion output differs at byte {offset}; evidence retained in {output}')
    sources = ['src/model/state/SuggestionState.zig', 'src/model/state/suggestion.zig',
               'src/gui/widgets/overlays/SuggestionPanel.zig', 'src/gui/widgets/overlays/PaletteLayout.zig',
               'src/gui/widgets/overlays/WrappedLines.zig', 'src/gui/widgets/ChromeMetrics.zig', 'src/gui/widgets/label_size.zig',
               'services/gui-cpp/suggestions/state.hpp', 'services/gui-cpp/presentation/suggestion_geometry.hpp',
               'services/gui-cpp/presentation/suggestion_labels.hpp', 'services/gui-cpp/presentation/suggestion_preview.hpp',
               'services/gui-cpp/tools/suggestion_probe.cpp', 'services/gui-cpp/tools/check_suggestions.py']
    result = dict(cases=len(cases), cases_by_kind=dict(Counter(kind for kind, _ in cases)),
                  input_sha256=hashlib.sha256(payload).hexdigest(), output_bytes=len(outputs['cpp']),
                  output_sha256=hashlib.sha256(outputs['cpp']).hexdigest(), reference_command=command,
                  binary_sha256={name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in binaries.items()},
                  source_sha256={name: hashlib.sha256((repository / name).read_bytes()).hexdigest() for name in sources},
                  scope='Original SuggestionState and full SuggestionPanel draw/footer bodies, original WrappedLines and ChromeMetrics, with only imports adapted. Canvas records labels, fills and button state; atlas returns the supplied grid. Valid wire text up to 1024 bytes. Does not establish native pixels, clipping/rasterization, full GUI parity or comparative performance.')
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({key: result[key] for key in ['cases', 'cases_by_kind', 'output_bytes', 'output_sha256']}, indent=2))


if __name__ == '__main__':
    main()
