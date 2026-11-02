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

from check_history_card import pack_text, protocol
from check_notification_center import function_source, run
from check_text_fit import unicode_facade


facades = r'''
const std = @import("std");
const io = @import("protocol.zig");
pub const Rect = struct { x: f32 = 0, y: f32 = 0, width: f32 = 0, height: f32 = 0 };
pub const Color = enum { subtext0, text, yellow, red, teal, accent, surface1 };
pub const label_size = struct { pub const Size = enum { terminal, title, body, small }; };
pub const Label = struct {
    text: []const u8,
    color: Color = .text,
    alpha: f32 = 1,
    face: enum { mono, sans } = .mono,
    size: label_size.Size = .terminal,
};
pub const ChromeMetrics = struct {
    const Metrics = @This();
    const sans_line_ratio: f32 = 1.3;
    ratio: f32 = 1,
    title: u16 = 0,
    body: u16 = 0,
    small: u16 = 0,
    __METRICS__
};
pub const key_label = struct { pub var host_style: enum { mac, pc } = .pc; };
pub const Entry = struct {
    cwd: []const u8,
    provider: []const u8,
    cwd_len: usize,
    provider_len: usize,
    status: enum { completed, interrupted, running },
    exit_code: ?i32,
    duration_ns: i64,
    started_at_ms: i64,
    author: enum { human, agent },
    captured_truncated: bool,
    pane_id: u64 = 0,
    pub fn cwdSlice(self: *@This()) []const u8 { return self.cwd; }
    pub fn providerSlice(self: *@This()) []const u8 { return self.provider; }
};
pub const History = struct {
    items: [1]Entry,
    now_ms: i64,
    loaded: bool,
    phase: enum { ready } = .ready,
    pub fn slice(self: *@This()) []Entry { return &self.items; }
    pub fn ownedCommand(self: *@This(), _: usize) ?[]const u8 { return if (self.loaded) "" else null; }
};
pub const Panes = struct {
    open: bool,
    pub fn findConst(self: @This(), _: u64) ?u8 { return if (self.open) 0 else null; }
};
pub const Projection = struct {
    history: *History,
    prompt: ?struct { generation: u64 = 0 } = .{},
    model: struct { panes: Panes },
};
pub const Target = struct {
    pub const Action = union(enum) { history: enum { copy, remove, visit_pane } };
    pub const Id = struct {
        generation: u64,
        pub fn eql(_: @This(), _: @This()) bool { return false; }
    };
    id: Id,
    namespace: u64,
    bounds: Rect,
    action: Action,
    layer: u8,
    focusable: bool,
    enabled: bool,
    pub fn labelled(self: @This(), _: []const u8) @This() { return self; }
};
pub const Dispatcher = struct {
    hovered: ?Target.Id = null,
    pub fn add(_: *@This(), target: Target) !Target.Id { return target.id; }
};
pub const WidgetState = struct { dispatcher: Dispatcher = .{} };
pub const Quads = struct {
    pub fn items(_: @This()) []const u8 { return ""; }
    pub fn clipFrom(_: *@This(), _: usize, bounds: Rect) void {
        io.write(@as(u8, 3)) catch unreachable;
        io.writeRect(bounds) catch unreachable;
    }
};
pub const Canvas = struct {
    chrome: ChromeMetrics,
    theme: struct { palette: struct {
        subtext0: Color = .subtext0, text: Color = .text, yellow: Color = .yellow,
        red: Color = .red, teal: Color = .teal, accent: Color = .accent, surface1: Color = .surface1,
    } = .{} } = .{},
    widgets: ?*WidgetState = null,
    quads: Quads = .{},
    fact_widths: [6]f32,
    action_widths: [3][2]f32,
    fact_index: usize = 0,
    pub fn measure(self: *@This(), label: Label) !f32 {
        const keys = if (key_label.host_style == .mac) [_][]const u8{ "⌘C", "⌘⌫", "⌥↩" } else [_][]const u8{ "Ctrl+C", "Ctrl+D", "Alt+Enter" };
        const words = [_][]const u8{ "copy", "delete", "go to pane" };
        for (keys, words, 0..) |key, word, index| {
            if (std.mem.eql(u8, label.text, key)) return self.action_widths[index][0];
            if (std.mem.eql(u8, label.text, word)) return self.action_widths[index][1];
        }
        defer self.fact_index += 1;
        return self.fact_widths[self.fact_index];
    }
    pub fn textAt(_: *@This(), bounds: Rect, label: Label) !f32 {
        try io.write(@as(u8, 2));
        try io.writeRect(bounds);
        try io.writeText(label.text);
        try io.writeText(@tagName(label.color));
        try io.write(label.alpha);
        return 0;
    }
    pub fn ringAt(_: *@This(), bounds: Rect, style: struct { color: Color, alpha: f32, width: f32, radius: f32 }) !void {
        try io.write(@as(u8, 1));
        try io.writeRect(bounds);
        try io.write(style.alpha);
        try io.write(style.width);
        try io.write(style.radius);
        try io.writeText(@tagName(style.color));
    }
    pub fn fillRoundedAt(_: *@This(), _: Rect, _: struct { color: Color, radius: f32 }) !void {}
};
'''


reference = r'''
const std = @import("std");
const io = @import("protocol.zig");
const types = @import("facades.zig");
const Row = @import("Row.zig");
const Hint = @import("HistoryHint.zig");
const labels = @import("history_labels.zig");
fn path() !void {
    const text = try io.readText();
    defer std.heap.page_allocator.free(text);
    var storage: [labels.path_bytes]u8 = undefined;
    try io.writeText(labels.compactPath(text, &storage));
}
fn meta() !void {
    types.key_label.host_style = if (try io.read(u8) == 0) .mac else .pc;
    const bounds = try io.readRect();
    const ratio = try io.read(f32);
    const small = try io.read(u16);
    const flags = try io.read(u16);
    const status = try io.read(u8);
    const exit_code = try io.read(i32);
    const duration = try io.read(i64);
    const now = try io.read(i64);
    const started = try io.read(i64);
    const more = try io.read(u16);
    const cwd = try io.readText();
    defer std.heap.page_allocator.free(cwd);
    const provider = try io.readText();
    defer std.heap.page_allocator.free(provider);
    var canvas: types.Canvas = .{ .chrome = .{ .ratio = ratio, .small = small }, .fact_widths = undefined, .action_widths = undefined };
    for (&canvas.fact_widths) |*width| width.* = try io.read(f32);
    for (&canvas.action_widths) |*action| for (action) |*width| { width.* = try io.read(f32); };
    var history: types.History = .{
        .now_ms = now,
        .loaded = flags & 4 != 0,
        .items = .{.{
            .cwd = cwd, .provider = provider, .cwd_len = cwd.len, .provider_len = provider.len,
            .status = @enumFromInt(status), .exit_code = if (flags & 32 != 0) exit_code else null,
            .duration_ns = duration, .started_at_ms = if (flags & 128 != 0) started else -1,
            .author = if (flags & 64 != 0) .agent else .human, .captured_truncated = flags & 16 != 0,
        }},
    };
    const projection: types.Projection = .{ .history = &history, .model = .{ .panes = .{ .open = flags & 2 != 0 } } };
    const row: Row = .{ .projection = &projection, .selected = flags & 1 != 0, .show_cwd = flags & 8 != 0 };
    try row.meta(&canvas, bounds, .{ .more = more });
    try io.write(@as(u8, 0));
}
fn hint() !void {
    types.key_label.host_style = if (try io.read(u8) == 0) .mac else .pc;
    const bounds = try io.readRect();
    const ratio = try io.read(f32);
    const small = try io.read(u16);
    const key = try io.read(f32);
    const word = try io.read(f32);
    var canvas: types.Canvas = .{ .chrome = .{ .ratio = ratio, .small = small }, .fact_widths = @splat(0), .action_widths = .{ .{ key, word }, .{ 0, 0 }, .{ 0, 0 } } };
    const control: Hint = .{ .bounds = bounds, .key = if (types.key_label.host_style == .mac) "⌘C" else "Ctrl+C", .word = "copy", .generation = 0, .namespace = .card };
    try io.write(try control.width(&canvas));
    try control.draw(&canvas);
    try io.write(@as(u8, 0));
}
pub fn main() !void {
    while (true) {
        switch (io.operation()) {
            -1 => return,
            0 => try path(),
            1 => try meta(),
            2 => try hint(),
            else => return error.InvalidOperation,
        }
    }
}
'''


def prepare_hint_sources(repository, output):
    overlay = repository / 'src/gui/widgets/overlays'
    hint = (overlay / 'HistoryHint.zig').read_text()
    for name in ['Canvas', 'Label', 'Target']:
        hint = re.sub(rf'const {name} = @import\("[^"\n]+"\);', f'const {name} = @import("facades.zig").{name};', hint)
    hint = hint.replace('@import("gfx")', '@import("facades.zig")')
    (output / 'HistoryHint.zig').write_text(hint)
    palette = 'const types = @import("facades.zig");\nconst Canvas = types.Canvas;\nconst Rect = types.Rect;\nconst Label = types.Label;\n'
    (output / 'PaletteRow.zig').write_text(palette + function_source((overlay / 'PaletteRow.zig').read_text(), 'keycap'))
    chrome = (repository / 'src/gui/widgets/ChromeMetrics.zig').read_text()
    metrics = '\n'.join(function_source(chrome, name) for name in ['px', 'text', 'rowHeight'])
    (output / 'facades.zig').write_text(facades.replace('__METRICS__', metrics))
    (output / 'protocol.zig').write_text(protocol)


def prepare(repository, build, output):
    prepare_hint_sources(repository, output)
    overlay = repository / 'src/gui/widgets/overlays'
    row_source = (overlay / 'HistoryRow.zig').read_text()
    row = '''const std = @import("std");
const types = @import("facades.zig");
const Canvas = types.Canvas;
const Rect = types.Rect;
const Label = types.Label;
const key_label = types.key_label;
const HistoryHint = @import("HistoryHint.zig");
const labels = @import("history_labels.zig");
const Row = @This();
projection: *const types.Projection,
index: usize = 0,
selected: bool,
show_cwd: bool,
const Wrapped = struct { more: u16 };
'''
    row += '\n'.join(re.findall(r'(?:pub )?const (?:min_command|more_bound):[^;]+;', row_source))
    row += '\n' + row_source[row_source.index('const mac_actions = '):row_source.index('// The card\'s last line:')]
    row += '\n' + function_source(row_source, 'meta').replace('fn meta(', 'pub fn meta(', 1)
    row += '\n' + function_source(row_source, 'metaFacts')
    (output / 'Row.zig').write_text(row)
    shutil.copyfile(overlay / 'history_labels.zig', output / 'history_labels.zig')
    for name in ['GraphemeIterator.zig', 'Cluster.zig', 'text.zig']:
        shutil.copyfile(repository / 'lib/cellgrid' / name, output / name)
    (output / 'cellgrid.zig').write_text('pub const GraphemeIterator = @import("GraphemeIterator.zig");\n')
    (output / 'unicode.zig').write_text(unicode_facade)
    (output / 'protocol.zig').write_text(protocol)
    (output / 'probe.zig').write_text(reference)
    cache = (build / 'CMakeCache.txt').read_text().splitlines()
    library = Path(next(line.split('=', 1)[1] for line in cache if line.startswith('GHOSTTY_VT_LIBRARY:FILEPATH=')))
    command = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', '-lc++', str(library),
               '--dep', 'cellgrid', f'-Mroot={output / "probe.zig"}', '--dep', 'unicode',
               f'-Mcellgrid={output / "cellgrid.zig"}', f'-Municode={output / "unicode.zig"}', f'-femit-bin={output / "original"}']
    with (output / 'reference-build.log').open('w') as log:
        subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
    return command, library


def path(value):
    return b'\0' + pack_text(value)


def meta(area=(0, 0, 1200, 28), ratio=1, small=11, style=0, flags=239, status=0, exit_code=1,
         duration=1_234_000_000, now=200_000, started=0, more=0, cwd=b'/work/project', provider=b'custom-agent',
         facts=(80, 80, 40, 50, 60, 80), actions=(18, 25, 25, 35, 25, 60)):
    return (struct.pack('<BB5fHHB i qqq H', 1, style, *area, ratio, small, flags, status, exit_code,
                        duration, now, started, more) + pack_text(cwd) + pack_text(provider)
            + struct.pack('<12f', *facts, *actions))


def hint(area, ratio, small, key, word, style):
    return struct.pack('<BB5fH2f', 2, style, *area, ratio, small, key, word)


def fixtures():
    paths = [b'', b'/', b'/' * 70, b'abc///', b'x' * 30, b'x' * 31,
             b'/' + b'parent/' * 12 + b'leaf', b'/parent/' + b'x' * 200,
             b'/very-long-parent-name/leaf////', b'a\x00b\tc\x1bd', b'a\xffb',
             b'\xc0\x80\xed\xa0\x80', b'a\xe2\x82',
             '/家庭/目录/项目/文件'.encode(), ('/a' + '\u0301' * 35 + '/Z').encode(),
             ('/👩🏽‍💻' * 12 + '/🇪🇸').encode()]
    for value, repeat in itertools.product(paths, [1, 2, 4]):
        yield path(value * repeat)
    for style, flags, status, more in itertools.product(range(2), range(256), range(3), [0, 1, 63, 64]):
        yield meta(style=style, flags=flags, status=status, more=more, area=(.25, .5, 5000, 28))
    for code, duration, started, now in itertools.product(
            [-(2**31), -1, 0, 1, 2**31 - 1], [-(2**63), 999_999, 60_000_000_000, 2**63 - 1],
            [0, 2**63 - 1], [-(2**63), 0, 2**63 - 1]):
        yield meta(exit_code=code, duration=duration, started=started, now=now, area=(0, 0, 5000, 28))
    densities = [.5, .8, 1, 1.25, 1.5, 2, 4, 8]
    for ratio, width, selected, pane in itertools.product(densities, [0, 1, 160, 260, 320, 800], [0, 1], [0, 2]):
        yield meta(area=(.25, .5, width * ratio, 28 * ratio), ratio=ratio, small=round(11 * ratio),
                   flags=(236 | selected | pane), facts=tuple(value * ratio for value in [80, 80, 40, 50, 60, 80]),
                   actions=tuple(value * ratio for value in [18, 25, 25, 35, 25, 60]))
    for ratio, width, height, style in itertools.product(densities, [0, 1, 10, 20, 50, 100, 200], [0, 1, 20, 28], range(2)):
        yield hint((.25, .5, width * ratio, height * ratio), ratio, round(11 * ratio), 40 * ratio, 80 * ratio, style)
    generator = random.Random(0x41573)
    alphabet = [b'a', b'B', b'/', b' ', b'\t', b'\x1b', b'\xff', b'\xe2\x82', '中'.encode(), 'á'.encode(), '👩🏽‍💻'.encode()]
    for _ in range(4000):
        value = b''.join(generator.choice(alphabet) for _ in range(generator.randrange(100)))
        yield path(value)
        ratio = generator.choice(densities)
        area = (generator.choice([0, .25, -1]), generator.choice([0, .5, 1]),
                generator.uniform(0, 1800) * ratio, generator.uniform(0, 40) * ratio)
        actions = tuple(generator.uniform(0, 100) * ratio for _ in range(6))
        yield meta(area=area, ratio=ratio, small=generator.randrange(1, 257), style=generator.randrange(2),
                   flags=generator.randrange(256), status=generator.randrange(3), more=generator.randrange(65),
                   cwd=value, provider=generator.choice([b'', b'custom-agent']),
                   facts=tuple(generator.uniform(0, 200) * ratio for _ in range(6)), actions=actions)
        yield hint(area, ratio, generator.randrange(1, 257), actions[0], actions[1], generator.randrange(2))


def main():
    parser = argparse.ArgumentParser(description='Compare history paths, metadata and action hints with original Zig methods')
    parser.add_argument('--build-dir', type=Path, default=Path(__file__).resolve().parents[1] / 'out')
    parser.add_argument('--output-dir', type=Path, required=True)
    options = parser.parse_args()
    repository = Path(__file__).resolve().parents[3]
    output = options.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    command, library = prepare(repository, options.build_dir.resolve(), output)
    cases = list(fixtures())
    payload = b''.join(cases)
    (output / 'input.bin').write_bytes(payload)
    expected = run(output / 'original', payload, output, 'original')
    actual = run(options.build_dir.resolve() / 'gui-history-facts-probe', payload, output, 'cpp')
    if actual != expected:
        offset = next((index for index, (left, right) in enumerate(zip(expected, actual)) if left != right), min(len(expected), len(actual)))
        raise RuntimeError(f'History facts mismatch at byte {offset}: original={len(expected)}, cpp={len(actual)}')
    sources = [Path(__file__), Path(__file__).with_name('history_facts_probe.cpp')]
    sources += [repository / value for value in [
        'src/gui/widgets/overlays/HistoryRow.zig', 'src/gui/widgets/overlays/HistoryHint.zig',
        'src/gui/widgets/overlays/PaletteRow.zig', 'src/gui/widgets/overlays/history_labels.zig',
        'src/gui/widgets/ChromeMetrics.zig', 'lib/cellgrid/GraphemeIterator.zig', 'lib/cellgrid/Cluster.zig',
        'services/gui-cpp/presentation/history_path.hpp', 'services/gui-cpp/presentation/history_actions.hpp',
        'services/gui-cpp/presentation/history_facts.hpp', 'services/gui-cpp/presentation/history_meta_geometry.hpp',
        'services/gui-cpp/presentation/history_hint_geometry.hpp', 'services/gui-cpp/text/grapheme_cursor.hpp',
    ]]
    result = dict(recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), records=len(cases),
                  input_sha256=hashlib.sha256(payload).hexdigest(), output_bytes=len(actual), output_sha256=hashlib.sha256(actual).hexdigest(),
                  reference_command=command, unicode_library_sha256=hashlib.sha256(library.read_bytes()).hexdigest(),
                  source_sha256={str(value.relative_to(repository)): hashlib.sha256(value.read_bytes()).hexdigest() for value in sources},
                  generated_sha256={str(value.relative_to(output)): hashlib.sha256(value.read_bytes()).hexdigest() for value in sorted(output.glob('*.zig'))},
                  scope='Original compactPath and its grapheme iterator are copied unchanged. Original HistoryRow.meta/metaFacts/action definitions, HistoryHint width/draw/keyWidth/wordLabel, PaletteRow.keycap and ChromeMetrics pixel/line-height methods are retained. Drawing and shaping use recording facades with premeasured advances. Compares ordered labels, colors, alpha, physical rectangles, rings and clipping. Pointer behavior, native pixels, animation and performance require separate checks.')
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print('Matched', len(cases), 'history facts records:', result['output_sha256'])


if __name__ == '__main__':
    main()
