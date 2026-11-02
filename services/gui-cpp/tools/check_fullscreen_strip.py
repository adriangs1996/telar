import argparse
import datetime
import hashlib
import json
from pathlib import Path
import random
import shutil
import struct
import subprocess

from check_notification_center import function_source, run


model_source = r'''
const std = @import("std");
const core = @import("telar-core");
pub const icons = struct {
    pub const Icon = enum(u8) {
        pane_fullscreen = 255,
        _,
        pub fn forApplication(name: []const u8) @This() { return @enumFromInt(std.fmt.parseInt(u8, name[1..], 10) catch unreachable); }
        pub fn unicodeGlyph(_: @This()) []const u8 { return "fullscreen"; }
    };
};
pub const Agent = struct {};
pub const Pane = struct {
    id: u64 = 0,
    name: []const u8 = "",
    attention: bool = false,
    pub fn foregroundName(self: @This()) []const u8 { return self.name; }
};
pub const Layout = struct {
    ids: [core.max_panes_per_tab]u64 = @splat(0),
    len: usize = 0,
    focus: u64 = 0,
    pub fn focused(self: @This()) ?u64 { return self.focus; }
    pub fn orderedPanes(self: @This(), storage: *[core.max_panes_per_tab]u64) []const u64 { @memcpy(storage[0..self.len], self.ids[0..self.len]); return storage[0..self.len]; }
};
pub const Panes = struct {
    items: [core.max_panes_per_tab]Pane = @splat(.{}),
    pub fn findInConst(self: *const @This(), _: u64, id: u64) ?*const Pane { return &self.items[id - 1]; }
};
pub const Model = struct {
    tabs: struct { location: [1]core.TabLocation = .{.{}}, layout: [1]Layout = .{.{}} } = .{},
    panes: Panes = .{},
    agent: Agent = .{},
};
'''

canvas_source = r'''
const std = @import("std");
const Rect = @import("gfx").Rect;
const Label = @import("Label.zig");
const core = @import("telar-core");
pub const empty: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
pub const Entry = struct { present: bool = false, bounds: Rect = empty, mark: Rect = empty, index: Rect = empty, name: Rect = empty, dot: Rect = empty };
const Canvas = @This();
chrome: struct { ratio: f32, pane_header: u32, pub fn px(self: @This(), value: f32) f32 { return value * self.ratio; } },
theme: struct { palette: struct { text: @import("cellgrid").Color = .text, subtext0: @import("cellgrid").Color = .subtext0, overlay1: @import("cellgrid").Color = .overlay1 } = .{} } = .{},
sizes: [core.max_panes_per_tab][2]f32 = @splat(.{0, 0}),
entries: [core.max_panes_per_tab]Entry = @splat(.{}),
mark_side: f32,
chip_width: f32,
progress_width: f32,
compact_width: f32,
chip: Rect = empty,
progress: Rect = empty,
leave: Rect = empty,
compacted: bool = false,
current: usize = 0,
pub fn measure(self: *Canvas, label: Label) !f32 {
    if (label.text.len != 0 and label.text[0] == 'p') {
        return self.sizes[try std.fmt.parseInt(usize, label.text[1..], 10)][1];
    }
    return self.sizes[(try std.fmt.parseInt(usize, label.text, 10)) - 1][0];
}
pub fn textAt(self: *Canvas, bounds: Rect, label: Label) !f32 {
    const name = label.text.len != 0 and label.text[0] == 'p';
    const index = if (name) try std.fmt.parseInt(usize, label.text[1..], 10) else (try std.fmt.parseInt(usize, label.text, 10)) - 1;
    self.current = index;
    if (name) { self.entries[index].name = bounds; } else { self.entries[index].present = true; self.entries[index].index = bounds; }
    if (bounds.width <= 0 or bounds.height <= 0) return 0;
    return @min(bounds.width, try self.measure(label));
}
pub fn iconSize(self: *const Canvas, _: Label) f32 { return self.mark_side; }
pub fn fillRoundedAt(self: *Canvas, bounds: Rect, _: anytype) !void { self.entries[self.current].dot = bounds; }
'''

context_source = r'''
const data = @import("model");
const core = @import("telar-core");
const Canvas = @import("Canvas.zig");
pub const Projection = struct { model: *const data.Model, tab: ?usize = 0 };
const Bands = struct {
    canvas: *Canvas,
    pub fn add(self: Bands, item: anytype) void { self.canvas.entries[item.action.intent.focus_pane - 1].bounds = item.area; }
};
projection: *const Projection,
progress: ?*anyopaque = null,
bands: Bands,
pub fn isHovered(_: *const @This(), _: anytype) bool { return false; }
'''

reference_source = r'''
const std = @import("std");
const core = @import("telar-core");
const data = @import("model");
const Rect = @import("gfx").Rect;
const Canvas = @import("Canvas.zig");
const Context = @import("Context.zig");
const Strip = @import("FullscreenStrip.zig");
extern "c" fn getchar() c_int;
extern "c" fn putchar(c_int) c_int;
fn read(comptime Value: type) !Value {
    var bytes: [@sizeOf(Value)]u8 = undefined;
    for (&bytes) |*byte| { const value = getchar(); if (value < 0) return error.TruncatedInput; byte.* = @intCast(value); }
    return @bitCast(bytes);
}
fn write(value: anytype) !void { for (std.mem.asBytes(&value)) |byte| { if (putchar(byte) < 0) return error.WriteFailed; } }
pub fn main() !void {
    while (true) {
        const operation = getchar(); if (operation < 0) break;
        if (operation != 0) return error.UnknownOperation;
        const row = try read(Rect);
        const ratio = try read(f32);
        const header = try read(u32);
        var canvas: Canvas = .{ .chrome = .{ .ratio = ratio, .pane_header = header }, .mark_side = try read(f32), .chip_width = try read(f32), .progress_width = try read(f32), .compact_width = try read(f32) };
        const count = try read(u8);
        var model: data.Model = .{};
        model.tabs.layout[0].len = count;
        var names: [core.max_panes_per_tab][16]u8 = undefined;
        for (0..count) |index| {
            model.tabs.layout[0].ids[index] = index + 1;
            canvas.sizes[index] = .{ try read(f32), try read(f32) };
            if (try read(u8) != 0) model.tabs.layout[0].focus = index + 1;
            const attention = try read(u8) != 0;
            model.panes.items[index] = .{ .id = index + 1, .name = try std.fmt.bufPrint(&names[index], "p{d}", .{index}), .attention = attention };
        }
        const projection: Context.Projection = .{ .model = &model };
        const context: Context = .{ .projection = &projection, .bands = .{ .canvas = &canvas } };
        try (Strip{ .context = &context, .tab = 0, .area = row }).draw(&canvas);
        try write(@as(u8, @intFromBool(canvas.compacted)));
        try write(canvas.chip); try write(canvas.progress); try write(canvas.leave);
        for (canvas.entries[0..count]) |entry| {
            try write(@as(u8, @intFromBool(entry.present))); try write(entry.bounds); try write(entry.mark); try write(entry.index); try write(entry.name); try write(entry.dot);
        }
    }
}
'''


def prepare(root, work):
    source = root / 'src/gui/widgets'
    shutil.copy2(source / 'FullscreenStrip.zig', work / 'FullscreenStrip.zig')
    (work / 'model.zig').write_text(model_source)
    (work / 'core.zig').write_text('pub const PaneId = u64; pub const max_panes_per_tab = 64; pub const TabLocation = struct { tab_id: u64 = 1 };\n')
    (work / 'gfx.zig').write_text('pub const Rect = extern struct { x: f32, y: f32, width: f32, height: f32 };\n')
    (work / 'cellgrid.zig').write_text('pub const Color = enum(u8) { default, text, subtext0, overlay1, yellow };\n')
    (work / 'Label.zig').write_text('text: []const u8, color: @import("cellgrid").Color = .default, bold: bool = false, face: enum { sans } = .sans, size: enum { body } = .body,\n')
    (work / 'Context.zig').write_text(context_source)
    (work / 'Canvas.zig').write_text(canvas_source)
    (work / 'action.zig').write_text('pub const Action = struct { intent: union(enum) { focus_pane: u64 } };\n')
    (work / 'attention.zig').write_text('''const data = @import("model"); const Context = @import("Context.zig"); const core = @import("telar-core"); const cellgrid = @import("cellgrid");
pub fn paneAgent(projection: *const Context.Projection, _: core.TabLocation, _: u64) ?*const data.Agent { return &projection.model.agent; }
pub fn paneDot(projection: *const Context.Projection, _: anytype, _: core.TabLocation, id: u64) ?cellgrid.Color { return if (projection.model.panes.items[id - 1].attention) .yellow else null; }
''')
    (work / 'StatusChip.zig').write_text('''const Rect = @import("gfx").Rect; const Canvas = @import("Canvas.zig");
context: *const @import("Context.zig"), agent: ?*const @import("model").Agent, area: Rect,
pub fn width(_: @This(), canvas: *Canvas) !f32 { return canvas.chip_width; }
pub fn draw(self: @This(), canvas: *Canvas) !void { canvas.chip = self.area; }
''')
    (work / 'PaneProgress.zig').write_text('''const Rect = @import("gfx").Rect; const Canvas = @import("Canvas.zig");
pane: *const @import("model").Pane, area: Rect, motions: ?*anyopaque, compact: bool = false,
pub fn width(self: @This(), canvas: *Canvas) !f32 { if (self.compact) canvas.compacted = true; return if (self.compact) canvas.compact_width else canvas.progress_width; }
pub fn draw(self: @This(), canvas: *Canvas) !void { const span = @min(self.area.width, try self.width(canvas)); canvas.progress = .{ .x = self.area.x + self.area.width - span, .y = self.area.y, .width = span, .height = self.area.height }; }
''')
    (work / 'PixelButton.zig').write_text('''const Rect = @import("gfx").Rect; const Canvas = @import("Canvas.zig");
context: *const @import("Context.zig"), area: Rect, intent: enum { toggle_pane_fullscreen }, text: []const u8, background: bool, alignment: enum { center },
pub fn draw(self: @This(), canvas: *Canvas) !void { canvas.leave = self.area; }
''')
    shutil.copy2(source / 'AttentionDot.zig', work / 'AttentionDot.zig')
    (work / 'application_mark.zig').write_text('''const Canvas = @import("Canvas.zig"); const Rect = @import("gfx").Rect;
pub fn draw(canvas: *Canvas, icon: @import("model").icons.Icon, bounds: Rect, _: bool) !void { canvas.entries[@intFromEnum(icon)].mark = bounds; }
''')
    original_tab = (source / 'TabStrip.zig').read_text()
    first = function_source(original_tab, 'firstVisible')
    (work / 'TabStrip.zig').write_text('const StripFit = struct { available: f32, gap: f32 };\n' + first)
    (work / 'probe.zig').write_text(reference_source)
    command = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', '--dep', 'model', '--dep', 'gfx', '--dep', 'cellgrid', '--dep', 'telar-core', f'-Mroot={work / "probe.zig"}', '--dep', 'telar-core', f'-Mmodel={work / "model.zig"}', f'-Mgfx={work / "gfx.zig"}', f'-Mcellgrid={work / "cellgrid.zig"}', f'-Mtelar-core={work / "core.zig"}', f'-femit-bin={work / "original"}']
    with (work / 'reference-build.log').open('w') as output:
        subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, check=True)
    return command


def case(row, ratio, height, side, chip, progress, compact, entries):
    return struct.pack('<B5fI4fB', 0, *row, ratio, height, side, chip, progress, compact, len(entries)) + b''.join(struct.pack('<ffBB', *entry) for entry in entries)


def fixtures():
    for ratio in [0.5, 0.75, 1, 1.25, 1.5, 2, 3]:
        for count in [1, 2, 4, 8, 64]:
            for focus in sorted({0, count // 2, count - 1}):
                entries = [(12*ratio, (20+index*3)*ratio, index == focus, index != focus and index % 2 == 0) for index in range(count)]
                for width in [0, 1, 16, 22, 36, 48, 64, 100, 180, 320, 700, 2400]:
                    for progress in [0, 70*ratio]:
                        yield case((0.25, 4.5, width*ratio, 30*ratio), ratio, round(22*ratio), 11*ratio, 60*ratio, progress, 24*ratio, entries)
    generator = random.Random(0x46554C4C)
    for _ in range(6000):
        ratio = generator.choice([0.5, 0.75, 1, 1.25, 1.5, 2, 3])
        count = generator.choice([1, 2, 3, 4, 8, 16, 32, 64])
        focus = generator.randrange(count)
        entries = [(generator.random()*30*ratio, generator.random()*200*ratio, index == focus, index != focus and bool(generator.randrange(2))) for index in range(count)]
        yield case((generator.random()*100, generator.random()*50, generator.random()*2000, generator.choice([0, 1, 15, 22, 40])*ratio), ratio, round(22*ratio), generator.choice([0, 7, 11, 14])*ratio, generator.choice([0, 60*ratio]), generator.choice([0, 90*ratio]), 24*ratio, entries)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build-dir', type=Path, default=Path(__file__).resolve().parents[1] / 'out')
    parser.add_argument('--output-dir', type=Path, required=True)
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    work = options.output_dir.resolve()
    work.mkdir(parents=True, exist_ok=False)
    command = prepare(root, work)
    cases = list(fixtures())
    payload = b''.join(cases)
    (work / 'input.bin').write_bytes(payload)
    expected = run(work / 'original', payload, work, 'original')
    actual = run(options.build_dir.resolve() / 'gui-fullscreen-strip-probe', payload, work, 'cpp')
    if expected != actual:
        offset = next((index for index, pair in enumerate(zip(expected, actual)) if pair[0] != pair[1]), min(len(expected), len(actual)))
        raise RuntimeError(f'Fullscreen strip mismatch at byte {offset}: original={len(expected)}, cpp={len(actual)}')
    paths = ['src/gui/widgets/FullscreenStrip.zig', 'src/gui/widgets/TabStrip.zig', 'src/gui/widgets/AttentionDot.zig', 'services/gui-cpp/presentation/fullscreen_strip_geometry.hpp', 'services/gui-cpp/tools/fullscreen_strip_probe.cpp', 'services/gui-cpp/tools/check_fullscreen_strip.py']
    result = dict(recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), cases=len(cases), input_sha256=hashlib.sha256(payload).hexdigest(), output_sha256=hashlib.sha256(actual).hexdigest(), source_sha256={name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in paths}, generated_sha256={path.name:hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(work.glob('*.zig'))}, reference_command=command, scope='Unchanged original FullscreenStrip and AttentionDot with the unchanged TabStrip.firstVisible function. Uses the bounded pane-order facade, injected text advances and recording mark/chip/progress/control painters. Compares requested label/mark/dot/control geometry and hidden-pane hit bands byte for byte. Font selection, raster output, focus-entry hit bounds, native input and comparative performance are outside this oracle.')
    (work/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    print('Matched',len(cases),'fullscreen strip frames:',result['output_sha256'])


if __name__ == '__main__':
    main()
