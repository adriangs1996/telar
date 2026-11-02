import argparse
import datetime
import hashlib
import json
from pathlib import Path
import random
import re
import shutil
import struct
import subprocess

from check_notification_center import function_source, run


model = r'''
pub const AgentStatus = __STATUS__;
pub const AgentBlockedReason = __REASON__;
pub const PaneProgressState = __PROGRESS__;
pub const Pane = struct {
    id: u64 = 1,
    progress_state: PaneProgressState = .remove,
    progress_percent: ?u8 = null,
    pub fn foregroundName(_: *const @This()) []const u8 { return "program"; }
};
pub const Agent = struct {
    status: AgentStatus = .unknown,
    reason: AgentBlockedReason = .none,
    seconds: u32 = 0,
    pub fn blockedReason(self: @This()) AgentBlockedReason { return self.reason; }
};
'''

context = r'''
const data = @import("model");
const Pauses = struct {
    paused: bool,
    pub fn contains(self: @This(), _: u64) bool { return self.paused; }
};
projection: struct { model: struct { graphics_pauses: Pauses } },
progress: ?*anyopaque = null,
pub fn statusAge(_: *const @This(), agent: *const data.Agent) u32 { return agent.seconds; }
'''

canvas = r'''
const std = @import("std");
const Rect = @import("gfx").Rect;
const Label = @import("Label.zig");
const Canvas = @This();
pub const Chrome = struct {
    ratio: f32,
    pane_header: u32,
    pub fn px(self: @This(), value: f32) f32 { return value * self.ratio; }
};
chrome: Chrome,
theme: struct { palette: struct { text: u8 = 0, subtext0: u8 = 0, yellow: u8 = 0, red: u8 = 0, teal: u8 = 0 } = .{} } = .{},
measurements: [6]f32,
rectangles: [5]Rect = @splat(.{ .x = 0, .y = 0, .width = 0, .height = 0 }),
compacted: bool = false,
last_label: []const u8 = "",
label_storage: [32]u8 = undefined,
pub fn measure(self: *Canvas, label: Label) !f32 {
    if (label.text.len <= self.label_storage.len) {
        @memcpy(self.label_storage[0..label.text.len], label.text);
        self.last_label = self.label_storage[0..label.text.len];
    }
    if (label.bold) return self.measurements[0];
    return if (std.mem.eql(u8, label.text, "images paused")) self.measurements[3] else self.measurements[1];
}
pub fn textAt(self: *Canvas, bounds: Rect, label: Label) !f32 {
    const index: usize = if (label.bold) 1 else if (std.mem.eql(u8, label.text, "images paused")) 3 else 2;
    self.rectangles[index] = bounds;
    if (bounds.width <= 0 or bounds.height <= 0) return 0;
    return @min(bounds.width, try self.measure(label));
}
'''

status_adapter = r'''
const data = @import("model");
const Rect = @import("gfx").Rect;
const Canvas = @import("Canvas.zig");
const Context = @import("Context.zig");
context: *const Context,
agent: ?*const data.Agent,
area: Rect,
pub fn width(self: @This(), canvas: *Canvas) !f32 { return if (self.agent != null) canvas.measurements[2] else 0; }
pub fn draw(self: @This(), canvas: *Canvas) !void { canvas.rectangles[4] = self.area; }
'''

progress_adapter = r'''
const data = @import("model");
const Rect = @import("gfx").Rect;
const Canvas = @import("Canvas.zig");
pane: *const data.Pane,
area: Rect,
motions: ?*anyopaque,
compact: bool = false,
pub fn width(self: @This(), canvas: *Canvas) !f32 {
    if (self.compact) canvas.compacted = true;
    return canvas.measurements[if (self.compact) @as(usize, 5) else 4];
}
pub fn draw(self: @This(), canvas: *Canvas) !void {
    const width_value = @min(self.area.width, try self.width(canvas));
    canvas.rectangles[0] = .{ .x = self.area.x + self.area.width - width_value, .y = self.area.y, .width = width_value, .height = self.area.height };
}
'''

reference = r'''
const std = @import("std");
const data = @import("model");
const Rect = @import("gfx").Rect;
const Context = @import("Context.zig");
const Canvas = @import("Canvas.zig");
const Header = @import("PaneHeader.zig");
const Status = @import("OriginalStatusChip.zig");
const Progress = @import("OriginalPaneProgress.zig");
extern "c" fn getchar() c_int;
extern "c" fn putchar(c_int) c_int;
fn read(comptime Value: type) !Value {
    var bytes: [@sizeOf(Value)]u8 = undefined;
    for (&bytes) |*byte| {
        const value = getchar();
        if (value < 0) return error.TruncatedInput;
        byte.* = @intCast(value);
    }
    return @bitCast(bytes);
}
fn write(value: anytype) !void {
    for (std.mem.asBytes(&value)) |byte| if (putchar(byte) < 0) return error.WriteFailed;
}
fn text(value: []const u8) !void {
    try write(@as(u8, @intCast(value.len)));
    for (value) |byte| try write(byte);
}
fn rect() !Rect {
    const x = try read(f32);
    const y = try read(f32);
    const width = try read(f32);
    return .{ .x = x, .y = y, .width = width, .height = try read(f32) };
}
fn context(paused: bool) Context { return .{ .projection = .{ .model = .{ .graphics_pauses = .{ .paused = paused } } } }; }
pub fn main() !void {
    while (true) {
        const operation = getchar();
        if (operation < 0) return;
        switch (operation) {
            0 => {
                const area = try rect();
                const ratio = try read(f32);
                const height = try read(u32);
                var values: [6]f32 = undefined;
                for (&values) |*value| value.* = try read(f32);
                const attention = try read(u8) != 0;
                const ctx = context(values[3] > 0);
                const pane: data.Pane = .{};
                const agent: data.Agent = .{ .status = if (attention) .blocked else .working };
                var canvas: Canvas = .{ .chrome = .{ .ratio = ratio, .pane_header = height }, .measurements = values };
                try (Header{ .context = &ctx, .pane = &pane, .agent = if (values[2] > 0) &agent else null, .index = 17, .area = area }).draw(&canvas);
                try write(@as(u8, @intFromBool(canvas.compacted)));
                for (canvas.rectangles) |bounds| {
                    try write(bounds.x); try write(bounds.y); try write(bounds.width); try write(bounds.height);
                }
            },
            1 => {
                const status: data.AgentStatus = @enumFromInt(try read(u8));
                const reason: data.AgentBlockedReason = @enumFromInt(try read(u8));
                const seconds = try read(u32);
                const ctx = context(false);
                const agent: data.Agent = .{ .status = status, .reason = reason, .seconds = seconds };
                var storage: [32]u8 = undefined;
                const value: Status = .{ .context = &ctx, .agent = &agent, .area = undefined };
                try text(value.text(&storage));
            },
            2 => {
                const state: data.PaneProgressState = @enumFromInt(try read(u8));
                const percent = try read(u8);
                const pane: data.Pane = .{ .progress_state = state, .progress_percent = percent };
                var canvas: Canvas = .{ .chrome = .{ .ratio = 1, .pane_header = 22 }, .measurements = @splat(0) };
                const value: Progress = .{ .pane = &pane, .area = undefined };
                _ = try value.width(&canvas);
                try text(canvas.last_label);
            },
            else => return error.InvalidOperation,
        }
    }
}
'''


def prepare(root, work):
    source = root / 'src/gui/widgets'
    types = (root / 'src/core/schema/types.zig').read_text()
    progress = (root / 'src/core/schema/messages/pane.zig').read_text()
    enum = lambda text, name: re.search(r'pub const ' + name + r' = (enum\(u8\) \{.*?\n\});', text, re.S).group(1)
    (work / 'model.zig').write_text(model.replace('__STATUS__', enum(types, 'AgentStatus')).replace('__REASON__', enum(types, 'AgentBlockedReason')).replace('__PROGRESS__', enum(progress, 'PaneProgressState')))
    for name in ['PaneHeader']:
        shutil.copy2(source / (name + '.zig'), work / (name + '.zig'))
    for name in ['StatusChip', 'PaneProgress']:
        shutil.copy2(source / (name + '.zig'), work / ('Original' + name + '.zig'))
    age = function_source((source / 'attention.zig').read_text(), 'ageLabel')
    (work / 'attention.zig').write_text('const std = @import("std");\nconst data = @import("model");\npub fn needsInput(status: data.AgentStatus) bool { return status == .blocked or status == .failed; }\n' + age)
    (work / 'Context.zig').write_text(context)
    (work / 'Canvas.zig').write_text(canvas)
    (work / 'StatusChip.zig').write_text(status_adapter)
    (work / 'PaneProgress.zig').write_text(progress_adapter)
    (work / 'Label.zig').write_text('text: []const u8, color: u8 = 0, bold: bool = false, face: enum {sans} = .sans, size: enum {body, small} = .body,\n')
    for name in ['ProgressRing', 'ProgressMotions']:
        (work / (name + '.zig')).write_text('')
    (work / 'gfx.zig').write_text('pub const Rect = struct { x: f32, y: f32, width: f32, height: f32 };\n')
    (work / 'cellgrid.zig').write_text('pub const Color = u8;\n')
    (work / 'probe.zig').write_text(reference)
    command = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', '--dep', 'model', '--dep', 'gfx', '--dep', 'cellgrid', f'-Mroot={work / "probe.zig"}', f'-Mmodel={work / "model.zig"}', f'-Mgfx={work / "gfx.zig"}', f'-Mcellgrid={work / "cellgrid.zig"}', f'-femit-bin={work / "original"}']
    with (work / 'reference-build.log').open('w') as output:
        subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, check=True)
    return command


def fixtures():
    for state in range(6):
        for reason in range(5):
            for seconds in [0, 1, 59, 60, 61, 3599, 3600, 86399, 86400, 365 * 86400, 2**32 - 1]:
                yield struct.pack('<BBBI', 1, state, reason, seconds)
    for state in range(5):
        for percent in range(256):
            yield struct.pack('<BBB', 2, state, percent)
    for ratio in [0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3]:
        for width in [0, 1, 8, 16, 24, 36, 48, 64, 80, 100, 120, 160, 240, 400]:
            for attention in [False, True]:
                for progress in [0, 24, 60, 100]:
                    values = [12 * ratio, 70 * ratio, 60 * ratio, 72 * ratio, progress * ratio, 24 * ratio]
                    yield struct.pack('<B5fI6fB', 0, 0.25, 4.5, width * ratio, 30 * ratio, ratio, round(22 * ratio), *values, attention)
    generator = random.Random(0x50414e45)
    for _ in range(12000):
        ratio = generator.choice([0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3])
        values = [generator.choice([0, generator.random() * 180]) * ratio for _ in range(5)]
        values.append(24 * ratio)
        yield struct.pack('<B5fI6fB', 0, generator.random() * 200, generator.random() * 60, generator.random() * 700, generator.choice([0, 1, 16, 22, 40]) * ratio, ratio, round(22 * ratio), *values, generator.randrange(2))


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
    actual = run(options.build_dir.resolve() / 'gui-pane-chrome-probe', payload, work, 'cpp')
    if expected != actual:
        offset = next((index for index, pair in enumerate(zip(expected, actual)) if pair[0] != pair[1]), min(len(expected), len(actual)))
        raise RuntimeError(f'Pane chrome mismatch at byte {offset}: original={len(expected)}, cpp={len(actual)}')
    sources = [source for source in (root / 'src/gui/widgets').glob('*.zig') if source.name in ['PaneHeader.zig', 'StatusChip.zig', 'PaneProgress.zig', 'attention.zig']]
    sources += [Path(__file__), root / 'services/gui-cpp/presentation/pane_chrome.hpp', root / 'services/gui-cpp/tools/pane_chrome_probe.cpp']
    result = dict(recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), cases=len(cases), geometry_frames=sum(case[0] == 0 for case in cases), status_labels=sum(case[0] == 1 for case in cases), progress_labels=sum(case[0] == 2 for case in cases), input_sha256=hashlib.sha256(payload).hexdigest(), output_sha256=hashlib.sha256(actual).hexdigest(), source_sha256={str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}, generated_sha256={str(path.relative_to(work)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(work.glob('*.zig'))}, reference_command=command, scope='Unchanged original PaneHeader.draw against injected premeasured advances and recording status/progress painters. Compares compact selection and all five requested physical rectangles byte for byte, including narrow/zero bands, fractional positions and attention priority. Unchanged original StatusChip.text, ageLabel and PaneProgress.width supply status/progress labels. This oracle does not establish font metrics, raster output, full pane geometry, fullscreen chrome or comparative performance.')
    (work / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print('Matched', result['cases'], 'pane chrome cases:', result['output_sha256'])


if __name__ == '__main__':
    main()
