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

from check_notification_center import function_source, run


facades = r'''
const std = @import("std");
pub const Rect = struct { x: f32 = 0, y: f32 = 0, width: f32 = 0, height: f32 = 0 };
pub const Color = enum { subtext0 };
pub const Label = struct { text: []const u8, color: Color = .subtext0, alpha: f32 = 1, face: enum { sans } = .sans, size: enum { small } = .small };
pub const ChromeMetrics = struct {
    const Metrics = @This();
    ratio: f32,
    pub __PIXELS__
};
pub const Entry = struct {
    author: enum { human, agent } = .human,
    cwd_len: usize = 0,
    started_at_ms: i64 = -1,
    pub fn cwdSlice(_: *@This()) []const u8 { return "cwd"; }
};
pub const History = struct {
    items: [1]Entry,
    utc_offset_min: i16 = 0,
    now_ms: i64 = 0,
    pub fn slice(self: *@This()) []Entry { return &self.items; }
};
pub const Projection = struct { history: *History };
pub const Canvas = struct {
    chrome: ChromeMetrics,
    theme: struct { palette: struct { subtext0: Color = .subtext0 } = .{} } = .{},
    cwd_width: f32,
    time_width: f32,
    provider: Rect = .{},
    cwd: Rect = .{},
    time: Rect = .{},
    pub fn measure(self: *@This(), label: Label) !f32 {
        return if (std.mem.eql(u8, label.text, "cwd")) self.cwd_width else self.time_width;
    }
    pub fn textAt(self: *@This(), bounds: Rect, label: Label) !f32 {
        if (std.mem.eql(u8, label.text, "cwd")) self.cwd = bounds else self.time = bounds;
        return 0;
    }
};
pub const labels = struct {
    pub const path_bytes = 61;
    pub fn compactPath(_: []const u8, _: *[path_bytes]u8) []const u8 { return "cwd"; }
    pub fn clock(_: i64, _: i16, _: []u8) []const u8 { return "time"; }
    pub fn dateLabel(_: i64, _: i64, _: i16, _: []u8) []const u8 { return "time"; }
};
'''


row_facade = r'''
const std = @import("std");
const types = @import("facades.zig");
const Canvas = types.Canvas;
const Rect = types.Rect;
const Label = types.Label;
const ChromeMetrics = types.ChromeMetrics;
const labels = types.labels;
const Row = @This();
projection: *const types.Projection,
index: usize = 0,
bounds: Rect,
row_height: f32,
show_cwd: bool,
time: enum { clock, date } = .clock,
__CONSTANTS__
__TOKEN__
__FACTS__
__INSET__
__LINE_ZONE__
__TEXT_COLUMN__
__MEASURE_FACTS__
__PAINT_FACTS__
fn mark(_: Row, canvas: *Canvas, bounds: Rect) !void { canvas.provider = bounds; }
pub fn derive(self: Row, canvas: *Canvas, needed: ?f32) ![6]Rect {
    const frame = self.inset(canvas);
    const zone = self.lineZone(canvas, frame);
    const px = canvas.chrome;
    const status: Rect = __STATUS_RECT__;
    var facts: Facts = .{};
    try self.measureFacts(canvas, &facts, .{ .width = zone.width, .needed = needed });
    try self.paintFacts(canvas, &facts, zone);
    return .{ frame, status, textColumn(zone, facts.reserved(px)), canvas.provider, canvas.cwd, canvas.time };
}
'''


reference = r'''
const std = @import("std");
const types = @import("facades.zig");
const Row = @import("Row.zig");
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
    for (std.mem.asBytes(&value)) |byte| {
        if (putchar(byte) < 0) return error.WriteFailed;
    }
}
fn frame() !void {
    const x = try read(f32);
    const y = try read(f32);
    const width = try read(f32);
    const height = try read(f32);
    const ratio = try read(f32);
    const row_height = try read(f32);
    const needed = try read(f32);
    const cwd_width = try read(f32);
    const time_width = try read(f32);
    const flags = try read(u8);
    var history: types.History = .{ .items = .{.{
        .author = if (flags & 1 != 0) .agent else .human,
        .cwd_len = if (flags & 4 != 0) 1 else 0,
        .started_at_ms = if (flags & 8 != 0) 0 else -1,
    }} };
    const projection: types.Projection = .{ .history = &history };
    const row: Row = .{
        .projection = &projection,
        .bounds = .{ .x = x, .y = y, .width = width, .height = height },
        .row_height = row_height,
        .show_cwd = flags & 2 != 0,
    };
    var canvas: types.Canvas = .{ .chrome = .{ .ratio = ratio }, .cwd_width = cwd_width, .time_width = time_width };
    for (try row.derive(&canvas, if (flags & 16 != 0) null else needed)) |area| {
        try write(area.x);
        try write(area.y);
        try write(area.width);
        try write(area.height);
    }
}
pub fn main() !void {
    while (true) {
        switch (getchar()) {
            -1 => return,
            0 => try frame(),
            else => return error.InvalidOperation,
        }
    }
}
'''


def prepare_sources(repository, output):
    source = (repository / 'src/gui/widgets/overlays/HistoryRow.zig').read_text()
    chrome = (repository / 'src/gui/widgets/ChromeMetrics.zig').read_text()
    substitutions = {
        '__CONSTANTS__': '\n'.join(re.findall(r'(?:pub )?const (?:mark_size|min_command):[^;]+;', source)),
        '__TOKEN__': source[source.index('const Token = struct {'):source.index('\n/// The facts of the first line')],
        '__FACTS__': source[source.index('const Facts = struct {'):source.index('\n// The command comes first.')],
        '__STATUS_RECT__': re.search(r'_ = try canvas.textAt\((\.\{\s*\.x = frame\.x.*?\n    \})', source, re.S).group(1),
    }
    for marker, name in [('__INSET__', 'inset'), ('__LINE_ZONE__', 'lineZone'), ('__TEXT_COLUMN__', 'textColumn'),
                         ('__MEASURE_FACTS__', 'measureFacts'), ('__PAINT_FACTS__', 'paintFacts')]:
        substitutions[marker] = function_source(source, name)
    row = row_facade
    for marker, text in substitutions.items():
        row = row.replace(marker, text)
    (output / 'Row.zig').write_text(row)
    (output / 'facades.zig').write_text(facades.replace('__PIXELS__', function_source(chrome, 'px').removeprefix('pub ')))


def prepare(repository, output):
    prepare_sources(repository, output)
    (output / 'probe.zig').write_text(reference)
    command = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', str(output / 'probe.zig'), f'-femit-bin={output / "original"}']
    with (output / 'reference-build.log').open('w') as log:
        subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
    return command


def request(area, ratio, row_height, command, cwd, time, flags):
    return struct.pack('<B9fB', 0, *area, ratio, row_height, command, cwd, time, flags)


def fixtures():
    densities = [.5, .8, 1, 1.25, 1.5, 2, 4, 8]
    for density, width, flags in itertools.product(densities, [0, 1, 68, 200, 242, 260, 320, 800, 1400], range(32)):
        yield request((0, 0, width * density, 64 * density), density, 34 * density, 100 * density, 90 * density, 40 * density, flags)
    generator = random.Random(0x41571)
    for _ in range(12000):
        density = generator.choice(densities)
        area = (generator.choice([0, .25, -1]), generator.choice([0, .5, 1]),
                generator.uniform(0, 1800) * density, generator.uniform(0, 800) * density)
        yield request(area, density, generator.uniform(0, 128) * density, generator.uniform(0, 3200) * density,
                      generator.uniform(0, 640) * density, generator.uniform(0, 100) * density, generator.randrange(32))


def main():
    parser = argparse.ArgumentParser(description='Compare history row fitting with original Zig methods')
    parser.add_argument('--build-dir', type=Path, default=Path(__file__).resolve().parents[1] / 'out')
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
    actual = run(options.build_dir.resolve() / 'gui-history-row-probe', payload, output, 'cpp')
    if actual != expected:
        offset = next((index for index, (left, right) in enumerate(zip(expected, actual)) if left != right), min(len(expected), len(actual)))
        raise RuntimeError(f'History row mismatch at byte {offset}, frame {offset // 96}: original={len(expected)}, cpp={len(actual)}')
    sources = [Path(__file__), Path(__file__).with_name('history_row_probe.cpp'),
               repository / 'services/gui-cpp/presentation/history_row_geometry.hpp',
               repository / 'services/gui-cpp/core/metrics.hpp', repository / 'services/gui-cpp/core/geometry.hpp',
               repository / 'src/gui/widgets/overlays/HistoryRow.zig', repository / 'src/gui/widgets/ChromeMetrics.zig']
    result = dict(recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), frames=len(cases),
                  input_sha256=hashlib.sha256(payload).hexdigest(), output_bytes=len(actual),
                  output_sha256=hashlib.sha256(actual).hexdigest(), reference_command=command,
                  source_sha256={str(path.relative_to(repository)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources},
                  generated_sha256={str(path.relative_to(output)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(output.glob('*.zig'))},
                  scope='Original inset, lineZone, textColumn, Facts, measureFacts and paintFacts methods are extracted without edits. The original status rectangle expression and pixel conversion are retained. Storage, drawing and label shaping use facades with premeasured advances. Six physical rectangles match for closed/expanded rows, all fact admissions and eight densities. This checks fitting, not compactPath, command wrapping, highlighting, card metadata/actions, native pixels or performance.')
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print('Matched', len(cases), 'history row frames:', result['output_sha256'])


if __name__ == '__main__':
    main()
