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

from check_history_rows import prepare_sources
from check_notification_center import function_source, run
from check_text_fit import unicode_facade


protocol = r'''
const std = @import("std");
extern "c" fn getchar() c_int;
extern "c" fn putchar(c_int) c_int;
pub fn read(comptime Value: type) !Value {
    var bytes: [@sizeOf(Value)]u8 = undefined;
    for (&bytes) |*byte| {
        const value = getchar();
        if (value < 0) return error.TruncatedInput;
        byte.* = @intCast(value);
    }
    return @bitCast(bytes);
}
pub fn write(value: anytype) !void {
    for (std.mem.asBytes(&value)) |byte| {
        if (putchar(byte) < 0) return error.WriteFailed;
    }
}
pub fn readText() ![]const u8 {
    const bytes = try std.heap.page_allocator.alloc(u8, try read(u16));
    for (bytes) |*byte| byte.* = try read(u8);
    return bytes;
}
pub fn writeText(text: []const u8) !void {
    try write(@as(u16, @intCast(text.len)));
    for (text) |byte| try write(byte);
}
pub fn readRect() !@import("facades.zig").Rect {
    const x = try read(f32);
    const y = try read(f32);
    const width = try read(f32);
    return .{ .x = x, .y = y, .width = width, .height = try read(f32) };
}
pub fn writeRect(area: @import("facades.zig").Rect) !void {
    try write(area.x);
    try write(area.y);
    try write(area.width);
    try write(area.height);
}
pub fn operation() c_int { return getchar(); }
'''


record_text = r'''
pub fn textAt(self: *@This(), bounds: Rect, label: Label) !f32 {
    if (label.face == .sans) {
        if (std.mem.eql(u8, label.text, "cwd")) self.cwd = bounds else self.time = bounds;
    } else if (label.bold) {
        try io.write(@as(u8, 1));
        try io.writeRect(bounds);
        try io.writeText(label.text);
    } else if (label.color == .subtext0) {
        self.marker = bounds;
        self.mark = label.text;
    } else {
        self.base = bounds;
    }
    return 0;
}
'''


row_probe = r'''
pub fn cardProbe(self: Row, canvas: *Canvas) !void {
    const frame = self.inset(canvas);
    const zone = self.lineZone(canvas, frame);
    var facts: Facts = .{};
    try self.measureFacts(canvas, &facts, .{ .width = zone.width, .needed = null });
    const column = textColumn(zone, facts.reserved(canvas.chrome));
    const command = self.shownCommand();
    const wrapped = wrap(command, columnsOf(canvas, column.width), self.line_limit);
    const intrinsic = try self.cardHeight(canvas);
    const cell: f32 = @floatFromInt(canvas.metrics.cell_height);
    const tallest = @max(self.row_height, self.viewport_height - canvas.chrome.px(4));
    const height = @min(tallest, opened(self.row_height, intrinsic, 1));
    try self.card(canvas, .{ .frame = frame, .text = column, .command = command });
    try io.write(intrinsic);
    try io.write(height);
    try io.write(column.y + topInset(column, cell));
    try io.writeRect(canvas.meta);
    try io.write(self.line_limit);
    try io.write(wrapped.shown);
    try io.write(wrapped.more);
    var lines: WrappedLines = .{ .text = command, .width = columnsOf(canvas, column.width), .words = true };
    for (0..wrapped.shown) |_| try io.writeText(lines.next().?);
}
pub fn commandProbe(canvas: *Canvas, bounds: Rect, text: []const u8, continues: bool, highlight: *MatchHighlight) !void {
    canvas.marker = .{};
    canvas.mark = "";
    try commandLine(canvas, .{ .bounds = bounds, .text = text, .continues = continues }, highlight);
    try io.write(@as(u8, 0));
    try io.writeRect(canvas.base);
    try io.writeRect(canvas.marker);
    try io.writeText(canvas.mark);
}
'''


reference = r'''
const std = @import("std");
const io = @import("protocol.zig");
const types = @import("facades.zig");
const Row = @import("Row.zig");
const HistoryRow = Row;
const WrappedLines = @import("WrappedLines.zig");
fn wrapping() !void {
    const columns = try io.read(u16);
    const words = try io.read(u8) != 0;
    const text = try io.readText();
    defer std.heap.page_allocator.free(text);
    var lines: WrappedLines = .{ .text = text, .width = columns, .words = words };
    while (lines.next()) |line| {
        try io.write(@as(u8, 1));
        try io.writeText(line);
    }
    try io.write(@as(u8, 0));
}
fn card() !void {
    const bounds = try io.readRect();
    const ratio = try io.read(f32);
    const row_height = try io.read(f32);
    const cell_width = try io.read(u32);
    const cell_height = try io.read(u32);
    const small = try io.read(u16);
    const viewport = try io.read(f32);
    const time_width = try io.read(f32);
    const flags = try io.read(u8);
    const text = try io.readText();
    defer std.heap.page_allocator.free(text);
    var history: types.History = .{ .items = .{.{
        .author = if (flags & 1 != 0) .agent else .human,
        .started_at_ms = if (flags & 2 != 0) 0 else -1,
    }}, .command = text };
    const projection: types.Projection = .{ .history = &history };
    var canvas: types.Canvas = .{ .chrome = .{ .ratio = ratio, .small = small }, .metrics = .{ .cell_width = cell_width, .cell_height = cell_height }, .cwd_width = 0, .time_width = time_width };
    const layout = .{ .results = .{ .height = viewport }, .row_height = row_height };
    const cell: f32 = @floatFromInt(@max(1, canvas.metrics.cell_height));
    const card_share: f32 = __CARD_SHARE__;
    __BUDGET__
    const row: Row = .{
        .projection = &projection, .bounds = bounds, .row_height = row_height,
        .show_cwd = true, .viewport_height = viewport, .line_limit = __LINE_LIMIT__,
    };
    try row.cardProbe(&canvas);
}
fn commandLines() !void {
    const bounds = try io.readRect();
    const cell_width = try io.read(u32);
    const query = try io.readText();
    defer std.heap.page_allocator.free(query);
    const count = try io.read(u16);
    var highlight: Row.MatchHighlight = .{ .query = query };
    var canvas: types.Canvas = .{ .chrome = .{ .ratio = 1 }, .metrics = .{ .cell_width = cell_width, .cell_height = 1 }, .cwd_width = 0, .time_width = 0 };
    for (0..count) |index| {
        const continues = try io.read(u8) != 0;
        const text = try io.readText();
        defer std.heap.page_allocator.free(text);
        var area = bounds;
        area.y += @as(f32, @floatFromInt(index)) * bounds.height;
        try Row.commandProbe(&canvas, area, text, continues, &highlight);
    }
    try io.write(@as(u16, @intCast(highlight.matched)));
}
pub fn main() !void {
    while (true) {
        switch (io.operation()) {
            -1 => return,
            0 => try wrapping(),
            1 => try card(),
            2 => try commandLines(),
            else => return error.InvalidOperation,
        }
    }
}
'''


def prepare(repository, build, output):
    prepare_sources(repository, output)
    row_source = (repository / 'src/gui/widgets/overlays/HistoryRow.zig').read_text()
    modal_source = (repository / 'src/gui/widgets/overlays/HistoryModal.zig').read_text()
    chrome_source = (repository / 'src/gui/widgets/ChromeMetrics.zig').read_text()
    row = (output / 'Row.zig').read_text()
    row = 'const io = @import("protocol.zig");\nconst cellgrid = @import("cellgrid");\nconst WrappedLines = @import("WrappedLines.zig");\n' + row
    row = row.replace('row_height: f32,', 'row_height: f32,\nviewport_height: f32,\nline_limit: u16,')
    row += '\n' + '\n'.join(re.findall(r'(?:pub )?const (?:max_lines|more_bound):[^;]+;', row_source))
    row += '\n' + row_source[row_source.index('const Wrapped = struct {'):row_source.index('\n// Counts wrapped lines')]
    row += '\n' + row_source[row_source.index('const MatchHighlight = struct {'):row_source.index('\nconst FirstLine')]
    row = row.replace('const MatchHighlight = struct', 'pub const MatchHighlight = struct')
    for name in ['shownCommand', 'columnsOf', 'topInset', 'metaHeight', 'wrap', 'cardHeight', 'card', 'commandLine']:
        row += '\n' + function_source(row_source, name)
    row += '\n' + function_source(modal_source, 'opened')
    row += '\nfn query(_: Row) []const u8 { return ""; }\n'
    row += 'fn meta(_: Row, canvas: *Canvas, area: Rect, _: Wrapped) !void { canvas.meta = area; }\n' + row_probe
    (output / 'Row.zig').write_text(row)

    types = (output / 'facades.zig').read_text()
    types = 'const io = @import("protocol.zig");\nconst cellgrid = @import("cellgrid");\nconst label_size = struct { pub const Size = enum { terminal, title, body, small }; };\n' + types
    types = types.replace('enum { subtext0 }', 'enum { subtext0, text, accent }')
    types = types.replace('alpha: f32 = 1,', 'alpha: f32 = 1, bold: bool = false,')
    types = types.replace('size: enum { small }', 'size: label_size.Size').replace('face: enum { sans } = .sans', 'face: enum { mono, sans } = .mono')
    types = types.replace('ratio: f32,', 'ratio: f32, title: u16 = 0, body: u16 = 0, small: u16 = 0,\nconst sans_line_ratio: f32 = 1.3;\npub ' + function_source(chrome_source, 'text').removeprefix('pub ') + '\npub ' + function_source(chrome_source, 'rowHeight').removeprefix('pub '))
    types = types.replace('pub fn cwdSlice', 'pub fn commandSlice(_: *@This()) []const u8 { return ""; }\n    pub fn cwdSlice')
    types = types.replace('items: [1]Entry,', 'items: [1]Entry, command: []const u8,')
    types = types.replace('pub fn slice', 'pub fn ownedCommand(self: *@This(), _: usize) ?[]const u8 { return self.command; }\n    pub fn slice')
    types = types.replace('subtext0: Color = .subtext0', 'subtext0: Color = .subtext0, text: Color = .text, accent: Color = .accent')
    types = types.replace('chrome: ChromeMetrics,', 'chrome: ChromeMetrics,\n    metrics: struct { cell_width: u32, cell_height: u32 },\n    meta: Rect = .{}, base: Rect = .{}, marker: Rect = .{}, mark: []const u8 = "",')
    measure = re.search(r'^    pub fn measure\([^\n]+\)[^\n]*\{\n.*?^    \}', types, re.M | re.S).group(0)
    types = types.replace(measure, measure.replace('return if (', 'if (label.face == .mono) return @floatFromInt(@as(u32, cellgrid.text.measure(label.text)) * self.metrics.cell_width);\n        return if ('))
    text_at = re.search(r'^    pub fn textAt\([^\n]+\)[^\n]*\{\n.*?^    \}', types, re.M | re.S).group(0)
    types = types.replace(text_at, record_text.strip())
    (output / 'facades.zig').write_text(types)
    (output / 'protocol.zig').write_text(protocol)
    probe = reference.replace('__CARD_SHARE__', re.search(r'const card_share: f32 = ([^;]+);', modal_source).group(1))
    probe = probe.replace('__BUDGET__', re.search(r'const budget = [^;]+;', modal_source).group(0))
    probe = probe.replace('__LINE_LIMIT__', re.search(r'\.line_limit = ([^;\n]+),', modal_source).group(1))
    (output / 'probe.zig').write_text(probe)
    shutil.copyfile(repository / 'src/gui/widgets/overlays/WrappedLines.zig', output / 'WrappedLines.zig')
    for name in ['GraphemeIterator.zig', 'Cluster.zig', 'text.zig']:
        shutil.copyfile(repository / 'lib/cellgrid' / name, output / name)
    (output / 'cellgrid.zig').write_text('pub const GraphemeIterator = @import("GraphemeIterator.zig");\npub const text = @import("text.zig");\n')
    (output / 'unicode.zig').write_text(unicode_facade)
    cache = (build / 'CMakeCache.txt').read_text().splitlines()
    library = next(line.split('=', 1)[1] for line in cache if line.startswith('GHOSTTY_VT_LIBRARY:FILEPATH='))
    command = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', '-lc++', library,
               '--dep', 'cellgrid', f'-Mroot={output / "probe.zig"}', '--dep', 'unicode',
               f'-Mcellgrid={output / "cellgrid.zig"}', f'-Municode={output / "unicode.zig"}', f'-femit-bin={output / "original"}']
    with (output / 'reference-build.log').open('w') as log:
        subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
    return command


def pack_text(value):
    return struct.pack('<H', len(value)) + value


def wrapping(text, columns, words):
    return struct.pack('<BHB', 0, columns, words) + pack_text(text)


def card(text, width, ratio, row_height, cell_width, cell_height, small, viewport, time_width, flags):
    return struct.pack('<B6fIIHffB', 1, 0, 0, width, row_height, ratio, row_height,
                       cell_width, cell_height, small, viewport, time_width, flags) + pack_text(text)


def command_lines(lines, query, columns, cell_width, continues=False):
    payload = struct.pack('<B4f', 2, .25, .5, columns * cell_width, 20) + struct.pack('<I', cell_width)
    payload += pack_text(query) + struct.pack('<H', len(lines))
    for text in lines:
        payload += struct.pack('<B', continues) + pack_text(text)
    return payload


def fixtures():
    texts = [b'', b'one two three', b'\r\n\n\r', b'one\r\ntwo\n', b' ' * 32,
             b'a\x00b\tc\x1bd', b'a\xffb', b'\xc0\x80\xed\xa0\x80', b'a\xe2\x82',
             'á中B 👩🏽‍💻 🇪🇸'.encode(), ('a' + '\u0301' * 35 + 'Z').encode(),
             b'x' * 2000, b'\n' * 5000]
    for text, columns, words in itertools.product(texts, [0, 1, 2, 3, 7, 8, 16, 80, 65535], [False, True]):
        yield wrapping(text, columns, words)
    densities = [.5, .8, 1, 1.25, 1.5, 2, 4, 8]
    for density, width, viewport, flags in itertools.product(densities, [0, 1, 200, 320, 800], [1, 100, 300, 800], range(4)):
        yield card(b'one two three\nsecond line\n' * 30, width * density, density,
                   34 * density, max(1, round(8 * density)), max(1, round(20 * density)),
                   max(1, round(11 * density)), viewport * density, 40 * density, flags)
    queries = [b'', b'CS', b'ab', '中bS'.encode(), 'á'.encode(), b'\xef\xbf\xbd']
    for text, query, width, continues in itertools.product(texts[:-1], queries, [0, .5, 1, 2, 4, 20], [False, True]):
        yield command_lines([text, b'second'], query, width, 8, continues)
    generator = random.Random(0x41572)
    alphabet = [b'a', b'B', b' ', b'\t', b'\r', b'\n', b'\xff', b'\xe2\x82', '中'.encode(), 'á'.encode(), '👩🏽‍💻'.encode()]
    for _ in range(6000):
        text = b''.join(generator.choice(alphabet) for _ in range(generator.randrange(100)))
        density = generator.choice(densities)
        yield wrapping(text, generator.choice([0, 1, 2, 7, 80]), bool(generator.randrange(2)))
        yield card(text, generator.uniform(0, 1800) * density, density, generator.uniform(1, 128) * density,
                   generator.randrange(1, 33), generator.randrange(1, 129), generator.randrange(1, 257),
                   generator.uniform(1, 1200) * density, generator.uniform(0, 100) * density, generator.randrange(4))
        yield command_lines([text, b'next line'], generator.choice(queries), generator.uniform(0, 150), generator.randrange(1, 33))


def main():
    parser = argparse.ArgumentParser(description='Compare history wrapping, card geometry and matching with original Zig methods')
    parser.add_argument('--build-dir', type=Path, default=Path(__file__).resolve().parents[1] / 'out')
    parser.add_argument('--output-dir', type=Path, required=True)
    options = parser.parse_args()
    repository = Path(__file__).resolve().parents[3]
    output = options.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    command = prepare(repository, options.build_dir.resolve(), output)
    cases = list(fixtures())
    payload = b''.join(cases)
    (output / 'input.bin').write_bytes(payload)
    expected = run(output / 'original', payload, output, 'original')
    actual = run(options.build_dir.resolve() / 'gui-history-card-probe', payload, output, 'cpp')
    if actual != expected:
        offset = next((index for index, (left, right) in enumerate(zip(expected, actual)) if left != right), min(len(expected), len(actual)))
        raise RuntimeError(f'History card mismatch at byte {offset}: original={len(expected)}, cpp={len(actual)}')
    sources = [Path(__file__), Path(__file__).with_name('history_card_probe.cpp'), Path(__file__).with_name('check_history_rows.py')]
    sources += [repository / path for path in ['src/gui/widgets/overlays/HistoryRow.zig', 'src/gui/widgets/overlays/HistoryModal.zig', 'src/gui/widgets/overlays/WrappedLines.zig', 'src/gui/widgets/ChromeMetrics.zig', 'lib/cellgrid/GraphemeIterator.zig', 'lib/cellgrid/text.zig', 'services/gui-cpp/core/unicode_scalar.hpp', 'services/gui-cpp/text/grapheme_cursor.hpp', 'services/gui-cpp/text/wrapped_lines.hpp', 'services/gui-cpp/presentation/history_card.hpp', 'services/gui-cpp/presentation/history_command_line.hpp', 'services/gui-cpp/presentation/history_match_highlight.hpp']]
    result = dict(recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), records=len(cases),
                  input_sha256=hashlib.sha256(payload).hexdigest(), output_bytes=len(actual), output_sha256=hashlib.sha256(actual).hexdigest(),
                  reference_command=command, unicode_library_sha256=hashlib.sha256(Path(command[6]).read_bytes()).hexdigest(),
                  source_sha256={str(path.relative_to(repository)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources},
                  generated_sha256={str(path.relative_to(output)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(output.glob('*.zig'))},
                  scope='Original WrappedLines and GraphemeIterator are copied unchanged. Original row wrapping, intrinsic height, commandLine and card placement methods, opened rounding, line budget and limit expressions are extracted unchanged. Storage, metadata drawing, label shaping and command ownership use facades. Glyph drawing is recorded as rectangles and text. Unicode width delegates to the configured Ghostty library on both sides. This verifies wrapping, bounded count, steady open height, metadata placement, clipping markers and visible fuzzy highlight byte/cell state; native font/pixel output, complete metadata/actions and animations remain open.')
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print('Matched', len(cases), 'history card records:', result['output_sha256'])


if __name__ == '__main__':
    main()
