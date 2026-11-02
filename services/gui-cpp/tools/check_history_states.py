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
pub const Color = enum(u8) { text, subtext0, surface0, accent };
pub const label_size = struct { pub const Size = enum(u8) { terminal, body, small, title }; };
pub const Label = struct {
    text: []const u8, color: Color = .text, bold: bool = false,
    face: enum(u8) { mono, sans } = .mono, size: label_size.Size = .terminal,
};
pub const Scope = enum(u8) { global, cwd, workspace, pane };
pub const Author = enum(u8) { all, human, agent };
pub const History = struct {
    const State = @This();
    phase: enum(u8) { idle, loading, ready, failed } = .idle,
    effective_scope: Scope = .global, page_offset: u32 = 0, has_page: bool = false,
    __INITIAL_LOADING__
};
pub const Filters = struct { query: []const u8 = "", author: Author = .human, failed_only: bool = false };
pub const Projection = struct {
    history: History = .{}, prompt: ?struct { generation: u64 = 1 } = .{},
    model: struct {
        workspace: []const u8 = "",
        pub fn workspaceName(self: *const @This()) []const u8 { return self.workspace; }
    } = .{},
};
pub const ChromeMetrics = struct {
    const Metrics = @This();
    const sans_line_ratio: f32 = 1.3;
    ratio: f32 = 1, title: u16 = 0, body: u16 = 0, small: u16 = 0,
    __METRICS__
};
pub const FrameClock = struct {
    const Clock = @This();
    now_ns: u64 = 0, deadline_ns: ?u64 = null,
    __CLOCK__
};
pub const Canvas = struct {
    chrome: ChromeMetrics = .{}, widths: [3]f32 = @splat(0), animation: ?*FrameClock = null,
    theme: struct { palette: struct { text: Color = .text, subtext0: Color = .subtext0, surface0: Color = .surface0, accent: Color = .accent } = .{} } = .{},
    quads: struct {
        pub fn items(_: *const @This()) struct { len: usize = 0 } { return .{}; }
        pub fn clipFrom(_: *@This(), _: usize, area: Rect) void { io.writeRect(area) catch unreachable; }
    } = .{},
    pub fn measure(self: *@This(), label: Label) !f32 {
        return self.widths[if (label.face == .mono) 2 else if (label.size == .small) 1 else 0];
    }
    pub fn textAt(self: *@This(), area: Rect, label: Label) !f32 {
        try io.write(@as(u8, 1));
        try io.writeRect(area);
        try io.writeText(label.text);
        try io.write(@as(u8, @intFromEnum(label.face)));
        try io.write(@as(u8, @intFromEnum(label.size)));
        try io.write(@as(u8, @intFromEnum(label.color)));
        try io.write(@as(u8, @intFromBool(label.bold)));
        return @min(area.width, try self.measure(label));
    }
    pub fn fillRoundedAt(_: *@This(), area: Rect, style: struct { color: Color, radius: f32 }) !void {
        try io.write(@as(u8, 2));
        try io.writeRect(area);
        try io.write(style.radius);
        try io.write(@as(u8, @intFromEnum(style.color)));
    }
    pub fn fillAt(_: *@This(), area: Rect, _: Color) !void { try io.writeRect(area); }
};
pub const FormButton = struct {
    bounds: Rect, text: []const u8,
    action: struct { history: struct { select_scope: Scope } },
    generation: u64, namespace: u64,
    pub fn draw(self: @This(), _: *Canvas) !void {
        try io.write(@as(u8, 3));
        try io.writeRect(self.bounds);
        try io.writeText(self.text);
    }
};
'''


modal = r'''
const std = @import("std");
const types = @import("facades.zig");
const Canvas = types.Canvas;
const Rect = types.Rect;
const Label = types.Label;
const FormButton = types.FormButton;
const HistoryModal = @This();
projection: *const types.Projection,
layout: struct { results: Rect, inspection: Rect },
filters: types.Filters,
__LOADING_CONSTANTS__
fn queryFilters(self: HistoryModal) types.Filters { return self.filters; }
__EMPTY__
__CENTERED__
__LOADING_LINE__
pub fn drawEmpty(self: HistoryModal, canvas: *Canvas) !void { try self.empty(canvas); }
pub fn drawLine(self: HistoryModal, canvas: *Canvas, area: Rect) !void { try self.loadingLine(canvas, area); }
'''


reference = r'''
const std = @import("std");
const io = @import("protocol.zig");
const types = @import("facades.zig");
const Modal = @import("Modal.zig");
const FrameClock = types.FrameClock;
const LoadingCue = struct {
    since_ns: ?u64 = null,
    __DELAY__
    __CUE__
};
fn empty() !void {
    const phase: @FieldType(types.History, "phase") = @enumFromInt(try io.read(u8));
    const scope: types.Scope = @enumFromInt(try io.read(u8));
    const author: types.Author = @enumFromInt(try io.read(u8));
    const flags = try io.read(u8);
    const offset = try io.read(u32);
    const workspace = try io.readText();
    defer std.heap.page_allocator.free(workspace);
    const area = try io.readRect();
    var canvas: types.Canvas = .{ .chrome = .{ .ratio = try io.read(f32), .body = try io.read(u16), .small = try io.read(u16) } };
    for (&canvas.widths) |*width| width.* = try io.read(f32);
    const projection: types.Projection = .{
        .history = .{ .phase = phase, .effective_scope = scope, .page_offset = offset, .has_page = flags & 1 != 0 },
        .model = .{ .workspace = workspace },
    };
    const value: Modal = .{
        .projection = &projection, .layout = .{ .results = area, .inspection = area },
        .filters = .{ .query = if (flags & 2 != 0) "query" else "", .author = author, .failed_only = flags & 4 != 0 },
    };
    try value.drawEmpty(&canvas);
    try io.write(@as(u8, 0));
}
fn cue(value: *LoadingCue) !void {
    const waiting = try io.read(u8) != 0;
    const has_clock = try io.read(u8) != 0;
    var clock: FrameClock = .{ .now_ns = try io.read(u64) };
    const visible = value.sample(waiting, if (has_clock) &clock else null);
    try io.write(@as(u8, @intFromBool(visible)));
    try io.write(@as(u8, @intFromBool(clock.deadline_ns != null)));
    try io.write(clock.deadline_ns orelse 0);
}
fn line() !void {
    const area = try io.readRect();
    var canvas: types.Canvas = .{ .chrome = .{ .ratio = try io.read(f32) } };
    const has_clock = try io.read(u8) != 0;
    var clock: FrameClock = .{ .now_ns = try io.read(u64) };
    canvas.animation = if (has_clock) &clock else null;
    const projection: types.Projection = .{};
    const value: Modal = .{ .projection = &projection, .layout = .{ .results = area, .inspection = area }, .filters = .{} };
    try value.drawLine(&canvas, area);
}
pub fn main() !void {
    var value: LoadingCue = .{};
    while (true) {
        const operation = io.read(u8) catch return;
        switch (operation) {
            0 => try empty(), 1 => try cue(&value), 2 => try line(), 3 => value = .{},
            else => unreachable,
        }
    }
}
'''


def prepare(repository, output):
    original = (repository / 'src/gui/widgets/overlays/HistoryModal.zig').read_text()
    metrics = (repository / 'src/gui/widgets/ChromeMetrics.zig').read_text()
    history = (repository / 'src/model/state/HistoryPaletteState.zig').read_text()
    clock = (repository / 'lib/animate/FrameClock.zig').read_text()
    cue = (repository / 'src/gui/widgets/overlays/LoadingCue.zig').read_text()
    adapted = facades.replace('__INITIAL_LOADING__', function_source(history, 'initialLoading'))
    adapted = adapted.replace('__METRICS__', '\n'.join(function_source(metrics, name) for name in ['px', 'text', 'rowHeight']))
    adapted = adapted.replace('__CLOCK__', '\n'.join(function_source(clock, name) for name in ['requestAt', 'step']))
    (output / 'facades.zig').write_text(adapted)
    adapted = modal
    for placeholder, name in [('__EMPTY__', 'empty'), ('__CENTERED__', 'centered'), ('__LOADING_LINE__', 'loadingLine')]:
        adapted = adapted.replace(placeholder, function_source(original, name))
    constants = '\n'.join(re.search(r'^const ' + name + r'[^\n]+;', original, re.M)[0] for name in ['loading_steps', 'loading_step_ns'])
    (output / 'Modal.zig').write_text(adapted.replace('__LOADING_CONSTANTS__', constants))
    adapted = reference.replace('__DELAY__', re.search(r'^pub const delay_ns[^\n]+;', cue, re.M)[0])
    (output / 'probe.zig').write_text(adapted.replace('__CUE__', function_source(cue, 'sample')))
    (output / 'protocol.zig').write_text(protocol)
    command = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', str(output / 'probe.zig'), '-femit-bin=' + str(output / 'original')]
    with (output / 'reference-build.log').open('w') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    return command


def empty(phase=2, scope=0, author=0, flags=1, offset=0, workspace=b'project', area=(0, 0, 700, 400), ratio=1, body=13, small=11, widths=(280, 440, 190)):
    return struct.pack('<5BI', 0, phase, scope, author, flags, offset) + pack_text(workspace) + struct.pack('<5f2H3f', *area, ratio, body, small, *widths)


def cue(waiting=True, now=0):
    return struct.pack('<BBBQ', 1, waiting, now is not None, now or 0)


def line(area=(0, 0, 700, 52), ratio=1, now=0):
    return struct.pack('<B5fBQ', 2, *area, ratio, now is not None, now or 0)


def fixtures():
    for phase, scope, author, flags, offset in itertools.product(range(4), range(4), range(3), range(8), [0, 80]):
        yield empty(phase=phase, scope=scope, author=author, flags=flags, offset=offset)
    for workspace in [b'', b'x' * 71, b'x' * 72, b'x' * 73, '中'.encode() * 24, '中'.encode() * 25, b'a\0b', b'a\xffb', 'café 👩🏽‍💻'.encode()]:
        yield empty(scope=2, workspace=workspace)
    for ratio, width, height, state in itertools.product([.5, .8, 1, 1.25, 1.5, 2, 4, 8], [0, 1, 15, 32, 100, 320, 900], [0, 1, 50, 400], [0, 1, 2, 3, 4]):
        phase, scope = [(1, 0), (3, 0), (2, 0), (2, 2), (2, 1)][state]
        yield empty(phase=phase, scope=scope, area=(.25, .5, width * ratio, height * ratio), ratio=ratio, body=max(1, round(13 * ratio)), small=max(1, round(11 * ratio)), widths=(280 * ratio, 440 * ratio, 190 * ratio))
    maximum = (1 << 64) - 1
    for start in [0, 1, 90_000_000, maximum - 150_000_001, maximum - 100_000_000, maximum]:
        yield b'\x03'
        for delta in [0, 1, 149_999_999, 150_000_000, 150_000_001, 900_000_000]:
            yield cue(now=min(maximum, start + delta))
        yield cue(False, min(maximum, start + 900_000_001))
        yield cue(now=None)
        yield cue(False, None)
        yield cue(now=start)
    generator = random.Random(0xE471C0)
    for _ in range(1200):
        yield b'\x03'
        start = generator.randrange(1 << 63)
        for step in range(8):
            yield cue(generator.randrange(5) != 0, None if generator.randrange(7) == 0 else start + step * 32_000_000)
    for ratio, width, step in itertools.product([.5, 1, 1.25, 2, 8], [0, 1, 17, 700], range(40)):
        yield line(area=(.25, .5, width * ratio, 52 * ratio), ratio=ratio, now=step * 24_000_000)
    yield line(now=None)
    yield line(now=maximum)


def main():
    parser = argparse.ArgumentParser(description='Compare history empty states, delayed loading cue and loading-line geometry with unchanged original Zig methods')
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
    actual = run(options.build_dir.resolve() / 'gui-history-states-probe', payload, output, 'cpp')
    if expected != actual:
        offset = next((index for index, (left, right) in enumerate(zip(expected, actual)) if left != right), min(len(expected), len(actual)))
        raise RuntimeError(f'History states differ at byte {offset}: original={len(expected)}, cpp={len(actual)}')
    sources = ['src/gui/widgets/overlays/HistoryModal.zig', 'src/gui/widgets/overlays/LoadingCue.zig', 'src/gui/widgets/ChromeMetrics.zig', 'src/model/state/HistoryPaletteState.zig', 'lib/animate/FrameClock.zig']
    sources += ['services/gui-cpp/' + name for name in ['presentation/history_empty.hpp', 'presentation/history_empty_geometry.hpp', 'presentation/history_loading.hpp', 'presentation/loading_cue.hpp', 'tools/history_states_probe.cpp', 'tools/check_history_states.py']]
    result = dict(recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), records=sum(case != b'\x03' for case in cases), input_sha256=hashlib.sha256(payload).hexdigest(), output_sha256=hashlib.sha256(actual).hexdigest(), output_bytes=len(actual), reference_command=command, source_sha256={name: hashlib.sha256((repository / name).read_bytes()).hexdigest() for name in sources}, scope='Original empty/centered/initialLoading/LoadingCue.sample/FrameClock.step methods, physical label and import rectangles, recovery-button intent, raw loading line and its clip rectangle. Shaping receives premeasured advances; button painting is a recording facade. Native pixels, application event delivery and comparative performance require separate checks.')
    (output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print('Matched', result['records'], 'original history state records')


if __name__ == '__main__':
    main()
