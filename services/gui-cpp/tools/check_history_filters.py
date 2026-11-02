import argparse
import datetime
import hashlib
import itertools
import json
from pathlib import Path
import random
import re
import struct
import subprocess

from check_history_card import pack_text, protocol
from check_notification_center import function_source, run


facades = r'''
const std = @import("std");
const io = @import("protocol.zig");
pub const Rect = struct { x: f32 = 0, y: f32 = 0, width: f32 = 0, height: f32 = 0 };
pub const Color = enum { text, subtext0, accent, red, surface0, surface1, overlay1 };
pub const Scope = enum { global, workspace, cwd, pane };
pub const Author = enum { human, agent, all };
pub const key_label = struct { pub var host_style: enum { mac, pc } = .mac; };
pub const Chrome = struct {
    ratio: f32,
    pub fn px(self: @This(), value: f32) f32 { return value * self.ratio; }
};
pub const Label = struct {
    text: []const u8,
    color: Color = .text,
    face: enum { mono, sans } = .mono,
    size: enum { terminal, small } = .terminal,
};
pub const Target = struct {
    pub const Action = union(enum) { history: union(enum) { select_scope: Scope, select_author: Author, toggle_failed } };
    id: struct { generation: u64 = 0 } = .{},
    bounds: Rect,
    action: Action,
    layer: u8 = 0,
    focusable: bool = false,
    pub fn labelled(self: @This(), _: []const u8) @This() { return self; }
};
pub const Id = struct {
    value: u8,
    pub fn eql(self: @This(), other: @This()) bool { return self.value == other.value; }
};
pub const Widgets = struct {
    dispatcher: struct {
        hovered: ?Id = null,
        pub fn add(_: *@This(), target: Target) !Id {
            return .{ .value = switch (target.action.history) {
                .select_scope => |scope| 1 + @as(u8, @intFromEnum(scope)),
                .select_author => |author| 5 + @as(u8, @intFromEnum(author)),
                .toggle_failed => 8,
            } };
        }
    } = .{},
};
pub const Projection = struct {
    prompt: ?struct { generation: u64 = 1 } = .{},
    history: struct { effective_scope: Scope },
};
pub const Canvas = struct {
    chrome: Chrome,
    theme: struct { palette: struct {
        text: Color = .text, subtext0: Color = .subtext0, accent: Color = .accent,
        red: Color = .red, surface0: Color = .surface0, surface1: Color = .surface1,
        overlay1: Color = .overlay1,
    } = .{} } = .{},
    widgets: ?*Widgets = null,
    scope_names: [4][]const u8,
    author_names: [3][]const u8,
    key_names: [3][]const u8,
    scope_widths: [4]f32,
    author_widths: [3]f32,
    key_widths: [3]f32,
    value_width: f32,
    failed_width: f32,
    pub fn measure(self: *@This(), label: Label) !f32 {
        if (label.face == .mono) {
            for (self.key_names, self.key_widths) |name, width| {
                if (std.mem.eql(u8, label.text, name)) return width;
            }
        } else {
            for (self.scope_names, self.scope_widths) |name, width| {
                if (std.mem.eql(u8, label.text, name)) return width;
            }
            for (self.author_names, self.author_widths) |name, width| {
                if (std.mem.eql(u8, label.text, name)) return width;
            }
            if (std.mem.eql(u8, label.text, "Failed")) return self.failed_width;
        }
        return self.value_width;
    }
    pub fn fillAt(_: *@This(), bounds: Rect, color: Color) !void {
        try io.write(@as(u8, 1)); try io.writeRect(bounds); try io.writeText(@tagName(color));
    }
    pub fn fillRoundedAt(_: *@This(), bounds: Rect, style: struct { color: Color, radius: f32 }) !void {
        try io.write(@as(u8, 2)); try io.writeRect(bounds); try io.write(style.radius); try io.writeText(@tagName(style.color));
    }
    pub fn ringAt(_: *@This(), bounds: Rect, style: struct { color: Color, width: f32, radius: f32, alpha: f32 }) !void {
        try io.write(@as(u8, 3)); try io.writeRect(bounds); try io.write(style.alpha);
        try io.write(style.width); try io.write(style.radius); try io.writeText(@tagName(style.color));
    }
    pub fn textAt(self: *@This(), bounds: Rect, label: Label) !f32 {
        if (bounds.width <= 0 or bounds.height <= 0) return 0;
        try io.write(@as(u8, 4)); try io.writeRect(bounds); try io.writeText(label.text);
        try io.writeText(@tagName(label.color)); try io.write(@as(u8, @intFromEnum(label.face)));
        try io.write(@as(u8, @intFromEnum(label.size)));
        return @min(bounds.width, try self.measure(label));
    }
};
'''

modal = r'''
const types = @import("facades.zig");
const Canvas = types.Canvas;
const Rect = types.Rect;
const Target = types.Target;
const HistoryModal = @This();
const key_label = types.key_label;
const data = struct { const PromptHistoryScope = types.Scope; };
const core = struct { const HistoryScope = types.Scope; const HistoryAuthorFilter = types.Author; };
const labels = struct { const path_bytes = 61; };
projection: *const types.Projection,
layout: struct { header: Rect },
value: []const u8,
author: types.Author,
failed_only: bool,
fn scopeValue(self: @This(), _: *[labels.path_bytes]u8) []const u8 { return self.value; }
fn queryFilters(self: @This()) struct { author: types.Author, failed_only: bool } { return .{ .author = self.author, .failed_only = self.failed_only }; }
pub fn draw(self: @This(), canvas: *Canvas) !void { try self.chips(canvas); }
pub fn scopeNames() [scope_chips.len][]const u8 {
    var result: [scope_chips.len][]const u8 = undefined;
    for (scope_chips, 0..) |chip, index| result[index] = chip.text;
    return result;
}
pub fn authorNames() [author_chips.len][]const u8 {
    var result: [author_chips.len][]const u8 = undefined;
    for (author_chips, 0..) |chip, index| result[index] = chip.text;
    return result;
}
pub fn keyNames() [3][]const u8 { return .{ keyText(.tab), keyText(.back_tab), "!" }; }
'''

reference = r'''
const std = @import("std");
const io = @import("protocol.zig");
const types = @import("facades.zig");
const Header = @import("Header.zig");
fn frame() !void {
    const area = try io.readRect();
    const ratio = try io.read(f32);
    types.key_label.host_style = if (try io.read(u8) == 0) .mac else .pc;
    const failed = try io.read(u8);
    const scope = try io.read(u8);
    const author = try io.read(u8);
    const hover = try io.read(u8);
    const value = try io.readText();
    defer std.heap.page_allocator.free(value);
    var widgets: types.Widgets = .{};
    widgets.dispatcher.hovered = if (hover == 0) null else .{ .value = hover };
    var canvas: types.Canvas = .{
        .chrome = .{ .ratio = ratio }, .widgets = &widgets,
        .scope_names = Header.scopeNames(), .author_names = Header.authorNames(), .key_names = Header.keyNames(),
        .scope_widths = undefined, .author_widths = undefined, .key_widths = undefined,
        .value_width = 0, .failed_width = 0,
    };
    for (&canvas.scope_widths) |*width| width.* = try io.read(f32);
    canvas.value_width = try io.read(f32);
    for (&canvas.author_widths) |*width| width.* = try io.read(f32);
    canvas.failed_width = try io.read(f32);
    for (&canvas.key_widths) |*width| width.* = try io.read(f32);
    const projection: types.Projection = .{ .history = .{ .effective_scope = @enumFromInt(scope) } };
    const header: Header = .{
        .projection = &projection, .layout = .{ .header = area }, .value = value,
        .author = @enumFromInt(author), .failed_only = failed != 0,
    };
    try header.draw(&canvas);
    try io.write(@as(u8, 0));
}
pub fn main() !void { while (io.operation() >= 0) try frame(); }
'''


def prepare(repository, output):
    source = (repository / 'src/gui/widgets/overlays/HistoryModal.zig').read_text()
    retained = [re.search(r'^const ' + name + r' = .*?^\};', source, re.M | re.S).group(0)
                for name in ['Chip', 'scope_chips', 'author_chips']]
    retained.extend(function_source(source, name) for name in ['chips', 'promptScope', 'keyText'])
    retained.append(re.search(r'^const KeyName = [^\n]+;', source, re.M).group(0))
    (output / 'Header.zig').write_text(modal + '\n\n'.join(retained))
    (output / 'facades.zig').write_text(facades)
    (output / 'protocol.zig').write_text(protocol)
    (output / 'probe.zig').write_text(reference)
    command = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', str(output / 'probe.zig'), '-femit-bin=' + str(output / 'original')]
    with (output / 'reference-build.log').open('w') as log:
        subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
    return command


def frame(width=1200, height=46, ratio=1, style=0, failed=0, scope=0, author=0, hover=0, value=b'', origin=(.25, .5), advances=None):
    if advances is None:
        advances = [18, 60, 48, 28, 50, 20, 36, 28, 32, 10, 20, 10]
        advances = [width * ratio for width in advances]
    return b'\0' + struct.pack('<5f5B', *origin, width, height, ratio, style, failed, scope, author, hover) + pack_text(value) + struct.pack('<12f', *advances)


def fixtures():
    ratios = [.5, .8, 1, 1.25, 1.5, 2, 4, 8]
    for ratio, width, height, style, scope, author, failed in itertools.product(ratios, [0, 1, 160, 320, 480, 640, 800, 1400], [0, 1, 12, 46], range(2), range(4), range(3), range(2)):
        yield frame(width=width * ratio, height=height * ratio, ratio=ratio, style=style, scope=scope, author=author, failed=failed, value=b'project' if scope in [1, 2] else b'')
    for ratio, scope, value, hover in itertools.product(ratios, [1, 2], [b'', b'project', b'/work/project', '工作/árbol'.encode()], range(9)):
        yield frame(width=1500 * ratio, height=46 * ratio, ratio=ratio, scope=scope, value=value, hover=hover, failed=1)
    generator = random.Random(0xF117E2)
    for _ in range(6000):
        ratio = generator.choice(ratios)
        scope = generator.randrange(4)
        widths = [generator.uniform(0, 150) * ratio for _ in range(12)]
        yield frame(width=generator.uniform(0, 2000) * ratio, height=generator.uniform(0, 80) * ratio, ratio=ratio,
                    style=generator.randrange(2), failed=generator.randrange(2), scope=scope, author=generator.randrange(3), hover=generator.randrange(9),
                    origin=(generator.uniform(-4, 4), generator.uniform(-4, 4)), advances=widths,
                    value=generator.choice([b'', b'project', '…/árbol'.encode()]) if scope in [1, 2] else b'')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build-dir', type=Path, required=True)
    parser.add_argument('--output-dir', type=Path, required=True)
    options = parser.parse_args()
    repository = Path(__file__).resolve().parents[3]
    output = options.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    command = prepare(repository, output)
    cases = list(fixtures())
    payload = b''.join(cases)
    (output / 'input.bin').write_bytes(payload)
    expected = run(output / 'original', payload, output, 'original')
    actual = run(options.build_dir.resolve() / 'gui-history-filters-probe', payload, output, 'cpp')
    if expected != actual:
        offset = next((index for index, (a, b) in enumerate(zip(expected, actual)) if a != b), min(len(expected), len(actual)))
        raise RuntimeError(f'History filter mismatch at byte {offset}: original={len(expected)}, cpp={len(actual)}')
    sources = [Path(__file__), Path(__file__).with_name('history_filters_probe.cpp'), repository / 'src/gui/widgets/overlays/HistoryModal.zig']
    sources.extend(repository / 'services/gui-cpp/presentation' / name for name in ['history_filter_labels.hpp', 'history_filter_chip_geometry.hpp', 'history_filter_geometry.hpp'])
    result = dict(recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), records=len(cases),
                  input_sha256=hashlib.sha256(payload).hexdigest(), output_bytes=len(actual), output_sha256=hashlib.sha256(actual).hexdigest(),
                  reference_command=command, source_sha256={str(path.relative_to(repository)):hashlib.sha256(path.read_bytes()).hexdigest() for path in sources},
                  generated_sha256={str(path.relative_to(output)):hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(output.glob('*.zig'))},
                  scope='Retains original Chip width/draw, filter header method, choice tables and key labels. Premeasured advances drive recorded fills, rings, text bounds, font roles, hover and fitting. Scope resolution, shaping, rasterization, event routing and performance are outside this oracle.')
    (output / 'result.json').write_text(json.dumps(result,indent=2)+'\n')
    print('Matched',len(cases),'history filter records:',result['output_sha256'])


if __name__ == '__main__':
    main()
