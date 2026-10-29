import argparse
import datetime
import hashlib
import json
from pathlib import Path
import random
import re
import struct
import subprocess

from check_activity_order import declaration, prepare_workspace_reference
from check_agent_presentation import enum_source
from check_task_labels import function_source


model_extension = r'''
pub const ColorName = enum { text, teal, red, yellow, green, overlay1 };
pub const Color = struct {
    r: f32 = 0, g: f32 = 0, b: f32 = 0, a: f32 = 1, name: ColorName = .text,
    pub fn rgb(value: u32, role: ColorName) @This() {
        return .{ .r = @as(f32, @floatFromInt((value >> 16) & 255)) / 255, .g = @as(f32, @floatFromInt((value >> 8) & 255)) / 255, .b = @as(f32, @floatFromInt(value & 255)) / 255, .name = role };
    }
};
pub const Palette = struct {
    text: Color = .rgb(0xffffff, .text), teal: Color = .rgb(0x72b7ae, .teal),
    red: Color = .rgb(0xf27c7c, .red), yellow: Color = .rgb(0xe8c56a, .yellow),
    green: Color = .rgb(0x9ccb8e, .green), overlay1: Color = .{ .name = .overlay1 },
};
pub const Pane = struct {
    id: core.PaneId, attachment_generation: u64,
    progress_state: core.PaneProgressState = .remove, progress_percent: ?u8 = null,
};
pub const tab_layout = struct {
    pub fn focusedPaneConst(model: anytype, _: usize) ?*const Pane { return model.focused; }
};
'''

reference = r'''
const std = @import("std");
const core = @import("telar-core");
const data = @import("model");
const animate = @import("animate");
const cellgrid = @import("cellgrid");
const Rect = @import("gfx").Rect;
const Ring = @import("ProgressRing.zig");
const PaneProgress = @import("PaneProgress.zig");
const Motions = @import("ProgressMotions.zig");
const Label = @import("Label.zig");
const TabStrip = @This();
const Layout = struct { panes: usize = 0, fn count(self: @This()) usize { return self.panes; } };
const Model = struct {
    tabs: struct { active: usize, location: [1]core.TabLocation, layout: [1]Layout },
    focused: ?*const data.Pane,
};
pub const Projection = struct {
    model: *const Model,
    agents: @FieldType(data.ClientModel, "agent_snapshot"),
};
const client = struct { pub const agent_attention = @import("agent_attention"); };
const attention = struct {
    __TAB_AGENT__
    __MOST_URGENT__
    __NEEDS_INPUT__
    __STATUS_COLOR__
};
const Context = struct { projection: *const Projection };
const Progress = struct {
    pane: *const data.Pane,
    __PROGRESS_COLOR__
};
__STATUS_TYPE__
__DOT_SIDE__
__SPINNER_SIDE__
context: *const Context,
__STATUS_OF__
__STATUS_WIDTH__

const Canvas = @import("Canvas.zig");
extern "c" fn getchar() c_int;
extern "c" fn putchar(c_int) c_int;
fn read(comptime Value: type) !Value {
    var result: Value = 0;
    for (0..@sizeOf(Value)) |index| {
        const byte = getchar();
        if (byte < 0) return error.TruncatedInput;
        result |= @as(Value, @intCast(byte)) << @intCast(index * 8);
    }
    return result;
}
fn float() !f32 { return @bitCast(try read(u32)); }
fn percent() !?u8 { const value = try read(u8); return if (value == 255) null else value; }
fn write(value: anytype) !void {
    var copy = value;
    for (std.mem.asBytes(&copy)) |byte| if (putchar(byte) < 0) { return error.WriteFailed; };
}
fn writeText(text: []const u8) !void {
    try write(@as(u16, @intCast(text.len)));
    for (text) |byte| if (putchar(byte) < 0) { return error.WriteFailed; };
}
fn readLocation() !core.TabLocation {
    const kind = try read(u8);
    const identity = try read(u64);
    return .{ .workspace = if (kind == 0) .{ .workspace = @enumFromInt(identity) } else .{ .worktree = @enumFromInt(identity) }, .tab_id = try read(u64) };
}
fn selection() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const memory = arena.allocator();
    const where = try readLocation();
    const selected = try read(u8) != 0;
    const panes = try read(u8);
    const present = try read(u8) != 0;
    const pane: data.Pane = .{ .id = @enumFromInt(1), .attachment_generation = 1, .progress_state = @enumFromInt(try read(u8)), .progress_percent = try percent() };
    const agents = try memory.alloc(data.Agent, try read(u8));
    for (agents) |*agent| {
        const pane_id: core.PaneId = @enumFromInt(try read(u64));
        const generation = try read(u64);
        const state: core.AgentStatus = @enumFromInt(try read(u8));
        const age = try read(u32);
        agent.* = .{ .key = .{ .pane_id = pane_id, .pane_generation = generation }, .location = try readLocation(), .status = state, .status_age_s = age };
    }
    const model: Model = .{ .tabs = .{ .active = if (selected) 0 else 1, .location = .{where}, .layout = .{.{ .panes = panes }} }, .focused = if (present) &pane else null };
    const projection: Projection = .{ .model = &model, .agents = .{ .entries = agents } };
    const context: Context = .{ .projection = &projection };
    const strip: TabStrip = .{ .context = &context };
    var canvas: Canvas = .{};
    const status = strip.statusOf(0, canvas.theme.palette);
    try write(@as(u8, @intCast(@intFromEnum(std.meta.activeTag(status)))));
    try write(try statusWidth(&canvas, status));
    const color = switch (status) {
        .none => canvas.theme.palette.text, .spinner => canvas.theme.palette.teal,
        .dot => |ink| ink, .progress => |value| (Progress{ .pane = value }).progressColor(&canvas),
    };
    try writeText(@tagName(color.name));
    const urgent = attention.tabAgent(&projection, where);
    const attention_color = if (urgent) |agent| if (attention.needsInput(agent.status)) attention.statusColor(canvas.theme.palette, agent.status) else canvas.theme.palette.text else canvas.theme.palette.text;
    try writeText(@tagName(attention_color.name));
}
fn ring() !void {
    const area: Rect = .{ .x = try float(), .y = try float(), .width = try float(), .height = try float() };
    const color: data.Color = .{ .r = try float(), .g = try float(), .b = try float(), .a = try float() };
    const fraction = try float();
    const rotation = try float();
    var canvas: Canvas = .{};
    try (Ring{ .area = area, .color = color, .fraction = fraction, .rotation = rotation }).draw(&canvas);
    try write(@as(u16, @intCast(canvas.count)));
    for (canvas.paints[0..canvas.count]) |paint| {
        for ([_]f32{paint.bounds.x, paint.bounds.y, paint.bounds.width, paint.bounds.height, paint.radius, paint.border, paint.fill.r, paint.fill.g, paint.fill.b, paint.fill.a, paint.outline.r, paint.outline.g, paint.outline.b, paint.outline.a}) |value| try write(value);
    }
}
fn capsule() !void {
    const area: Rect = .{ .x = try float(), .y = try float(), .width = try float(), .height = try float() };
    const ratio = try float();
    const pane: data.Pane = .{ .id = @enumFromInt(1), .attachment_generation = 1, .progress_state = @enumFromInt(try read(u8)), .progress_percent = try percent() };
    var clock: animate.FrameClock = .{ .now_ns = try read(u64) };
    var canvas: Canvas = .{};
    canvas.quads = .{ .owner = &canvas };
    canvas.chrome.ratio = ratio;
    canvas.animation = &clock;
    try (PaneProgress{ .pane = &pane, .area = area, .compact = true }).draw(&canvas);
    try write(@as(u16, @intCast(canvas.count)));
    for (canvas.paints[0..canvas.count]) |paint| {
        for ([_]f32{paint.bounds.x, paint.bounds.y, paint.bounds.width, paint.bounds.height, paint.radius, paint.border, paint.fill.r, paint.fill.g, paint.fill.b, paint.fill.a, paint.outline.r, paint.outline.g, paint.outline.b, paint.outline.a}) |value| try write(value);
    }
}
fn motion(motions: *Motions) !void {
    const pane: data.Pane = .{ .id = @enumFromInt(try read(u64)), .attachment_generation = try read(u64), .progress_state = @enumFromInt(try read(u8)), .progress_percent = try percent() };
    var clock: animate.FrameClock = .{ .now_ns = try read(u64) };
    const visible = try read(u8) != 0;
    motions.begin();
    const value = if (visible) motions.fraction(&pane, &clock) else 0;
    motions.end();
    try write(value);
}
fn indeterminate() !void {
    var clock: animate.FrameClock = .{ .now_ns = try read(u64) };
    var fraction: f32 = 0;
    var rotation: f32 = 0;
    __INDETERMINATE__
    try write(fraction);
    try write(rotation);
}
pub fn main() !void {
    var motions: Motions = .{};
    while (true) {
        const operation = getchar();
        if (operation < 0) return;
        switch (operation) {
            0 => try selection(), 1 => try ring(), 2 => try motion(&motions), 3 => try indeterminate(), 4 => try capsule(),
            else => return error.InvalidOperation,
        }
    }
}
'''


canvas_source = r'''
const std = @import("std");
const data = @import("model");
const Rect = @import("gfx").Rect;
const Label = @import("Label.zig");
const Canvas = @This();
const Quads = struct {
    owner: *Canvas,
    pub fn items(self: @This()) []Paint { return self.owner.paints[0..self.owner.count]; }
    pub fn fadeFrom(self: @This(), first: usize, alpha: f32) void {
        for (self.owner.paints[first..self.owner.count]) |*paint| {
            paint.fill.a *= alpha;
            paint.outline.a *= alpha;
        }
    }
    pub fn clipFrom(_: @This(), _: usize, _: Rect) void {}
};
const Paint = struct { bounds: Rect, radius: f32, border: f32, fill: data.Color, outline: data.Color };

    theme: struct { palette: data.Palette = .{} } = .{},
    chrome: struct { ratio: f32 = 1, pub fn px(self: @This(), value: f32) f32 { return self.ratio * value; } } = .{},
    quads: Quads = undefined,
    animation: ?*@import("animate").FrameClock = null,
    paints: [69]Paint = undefined,
    count: usize = 0,
    pub fn textAt(_: *Canvas, _: Rect, _: Label) !f32 { return 0; }
    pub fn measure(_: *Canvas, _: Label) !f32 { return 0; }
    pub fn fillRoundedAt(self: *Canvas, bounds: Rect, fill: struct { radius: f32, color: data.Color }) !void {
        self.paints[self.count] = .{ .bounds = bounds, .radius = @min(fill.radius, @min(bounds.width, bounds.height) / 2), .border = 0, .fill = fill.color, .outline = .{ .a = 0 } };
        self.count += 1;
    }
    pub fn ringAt(self: *Canvas, bounds: Rect, stroke: struct { width: f32, radius: f32, color: data.Color, alpha: f32 }) !void {
        var color = stroke.color;
        color.a *= stroke.alpha;
        self.paints[self.count] = .{ .bounds = bounds, .radius = @min(stroke.radius, @min(bounds.width, bounds.height) / 2), .border = stroke.width, .fill = .{ .a = 0 }, .outline = color };
        self.count += 1;
    }
'''


def prepare(root, work):
    prepare_workspace_reference(root, work)
    types = (root / 'src/core/schema/types.zig').read_text()
    core = work / 'core.zig'
    core.write_text(core.read_text() + '\n' + enum_source((root / 'src/core/schema/messages/pane.zig').read_text(), 'PaneProgressState') + '\n' + declaration(types, 'max_panes_per_tab'))
    model = work / 'model.zig'
    model.write_text(model.read_text() + model_extension)
    (work / 'Canvas.zig').write_text(canvas_source)
    (work / 'Label.zig').write_text('text: []const u8, color: @import("model").Color, face: enum { sans }, size: enum { small },\n')
    (work / 'gfx.zig').write_text('pub const Rect = struct { x: f32, y: f32, width: f32, height: f32 };\n')
    (work / 'cellgrid.zig').write_text('pub const Color = @import("model").Color;\n')
    for name in ['ProgressRing', 'PaneProgress', 'ProgressMotions']:
        source = (root / f'src/gui/widgets/{name}.zig').read_text()
        (work / (name + '.zig')).write_text(source)
    tabs = (root / 'src/gui/widgets/TabStrip.zig').read_text()
    attention = (root / 'src/gui/widgets/attention.zig').read_text()
    progress = (root / 'src/gui/widgets/PaneProgress.zig').read_text()
    replacements = {
        '__TAB_AGENT__': function_source(attention, 'tabAgent').replace('client.Projection', 'Projection'),
        '__MOST_URGENT__': function_source(attention, 'mostUrgent'),
        '__NEEDS_INPUT__': function_source(attention, 'needsInput'),
        '__STATUS_COLOR__': function_source(attention, 'statusColor'),
        '__PROGRESS_COLOR__': function_source(progress, 'progressColor'),
        '__STATUS_TYPE__': re.search(r'const Status = union\(enum\) \{.*?\n\};', tabs, re.DOTALL).group(0),
        '__DOT_SIDE__': re.search(r'^const dot_side[^\n]+', tabs, re.MULTILINE).group(0),
        '__SPINNER_SIDE__': re.search(r'^const spinner_side[^\n]+', tabs, re.MULTILINE).group(0),
        '__STATUS_OF__': function_source(tabs, 'statusOf'),
        '__STATUS_WIDTH__': function_source(tabs, 'statusWidth'),
        '__INDETERMINATE__': re.search(r'if \(self.pane.progress_state == \.indeterminate\) \{(.*?clock.requestAt\([^;]+;)', progress, re.DOTALL).group(1),
    }
    source = reference
    for marker, value in replacements.items():
        source = source.replace(marker, value)
    (work / 'probe.zig').write_text(source)
    command = [
        'zig', 'build-exe', '-O', 'ReleaseSafe', '-lc',
        '--dep', 'model', '--dep', 'telar-core', '--dep', 'agent_attention', '--dep', 'cellgrid', '--dep', 'gfx', '--dep', 'animate', f'-Mroot={work / "probe.zig"}',
        '--dep', 'telar-core', '--dep', 'workspace', f'-Mmodel={work / "model.zig"}',
        '--dep', 'telar-core', f'-Mworkspace={work / "workspace.zig"}',
        '--dep', 'model', f'-Mcellgrid={work / "cellgrid.zig"}', f'-Mgfx={work / "gfx.zig"}',
        '--dep', 'telar-core', '--dep', 'model', f'-Magent_attention={root / "src/client/agents/attention.zig"}',
        f'-Manimate={root / "lib/animate/root.zig"}', f'-Mtelar-core={work / "core.zig"}', f'-femit-bin={work / "original"}',
    ]
    result = subprocess.run(command, capture_output=True, text=True)
    (work / 'reference-build.log').write_text(result.stdout + result.stderr)
    result.check_returncode()
    return command


def requests():
    generator = random.Random(0x7E1A)
    for state in range(6):
        for selected in [False, True]:
            for panes in [0, 1, 2, 64]:
                for progress in range(5):
                    header = struct.pack('<BBQQBBBBBB', 0, 0, 1, 1, selected, panes, True, progress, 25 if progress in [1, 2, 4] else 255, 1)
                    yield header + struct.pack('<QQBIBQQ', 1, 1, state, 0, 0, 1, 1)
    for _ in range(300):
        reports = generator.randrange(65)
        header = struct.pack('<BBQQBBBBBB', 0, 0, 1, 1, generator.randrange(2), generator.choice([0, 1, 2, 64]), generator.randrange(2), generator.randrange(5), 50, reports)
        for index in range(reports):
            header += struct.pack('<QQBIBQQ', index + 1, generator.randrange(1, 4), generator.randrange(6), generator.choice([0, 1, 5, 59, 2**32-1]), generator.randrange(2), generator.randrange(1, 3), generator.randrange(1, 3))
        yield header
    for side in [1, 2, 6, 12, 14, 17.5, 28, 64]:
        for fraction in [0, .01, .22, .3, .5, .65, 1]:
            for frame in range(8):
                yield struct.pack('<B10f', 1, 3.25, 7.5, side, side, .2, .7, .6, 1, fraction, frame / 8)
    timestamp = 1_000_000_000
    for group in range(400):
        target = generator.randrange(101)
        for elapsed in [0, 1, 10_000_000, 120_000_000, 239_999_999, 240_000_000, 500_000_000]:
            yield struct.pack('<BQQBBQB', 2, 1, group // 20 + 1, generator.choice([1, 1, 1, 2, 3, 4]), target, timestamp + elapsed, generator.choice([1, 1, 1, 0]))
        timestamp += 600_000_000
    for ratio in [.5, 1, 1.1, 1.25, 2, 3]:
        for width, height in [(0, 30), (6, 30), (12, 30), (24, 30), (32, 5), (48, 60)]:
            for state in range(5):
                for percent in [0, 25, 100, 255]:
                    yield struct.pack('<B5fBBQ', 4, 3.25, 7.5, width, height, ratio, state, percent, 1_200_000_000)
    for now in [0, 1, 1_399_999_999, 1_400_000_000, *[generator.randrange(2**64) for _ in range(1000)]]:
        yield struct.pack('<BQ', 3, now)


def run(binary, payload, work, name):
    result = subprocess.run([binary], input=payload, capture_output=True, timeout=180)
    (work / (name + '.bin')).write_bytes(result.stdout)
    (work / (name + '-stderr.log')).write_bytes(result.stderr)
    result.check_returncode()
    return result.stdout


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build-dir', type=Path, default=Path(__file__).resolve().parents[1] / 'out')
    parser.add_argument('--output-dir', type=Path, required=True)
    options = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    work = options.output_dir.resolve()
    work.mkdir(parents=True, exist_ok=False)
    command = prepare(root, work)
    cases = list(requests())
    payload = b''.join(cases)
    (work / 'input.bin').write_bytes(payload)
    expected = run(work / 'original', payload, work, 'original')
    actual = run(options.build_dir.resolve() / 'gui-tab-activity-probe', payload, work, 'cpp')
    if expected != actual:
        offset = next((index for index, pair in enumerate(zip(expected, actual)) if pair[0] != pair[1]), min(len(expected), len(actual)))
        raise RuntimeError(f'Tab activity mismatch at output byte {offset}: original={len(expected)}, cpp={len(actual)}')
    files = [
        'src/gui/widgets/TabStrip.zig', 'src/gui/widgets/attention.zig',
        'src/gui/widgets/ProgressRing.zig', 'src/gui/widgets/PaneProgress.zig',
        'src/gui/widgets/ProgressMotions.zig', 'src/client/agents/attention.zig',
        'src/core/schema/types.zig', 'src/core/schema/messages/pane.zig',
        'services/gui-cpp/presentation/tab_activity.hpp',
        'services/gui-cpp/presentation/progress_geometry.hpp',
        'services/gui-cpp/presentation/progress_motion.hpp',
        'services/gui-cpp/presentation/progress_animation.hpp',
        'services/gui-cpp/graphics/progress_ring.hpp',
        'services/gui-cpp/graphics/progress_capsule.hpp',
        'services/gui-cpp/core/cosine.hpp',
        'services/gui-cpp/platform/progress_cosine.hpp',
        'services/gui-cpp/tools/tab_activity_probe.cpp',
        'services/gui-cpp/tools/check_tab_activity.py',
        'services/gui-cpp/tools/check_activity_order.py',
    ]
    files += [str(path.relative_to(root)) for path in sorted((root / 'lib/animate').rglob('*.zig'))]
    generated = [path for path in sorted(work.glob('*.zig')) if not path.is_symlink()]
    result = dict(
        recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        cases=len(cases), output_bytes=len(actual), output_sha256=hashlib.sha256(actual).hexdigest(),
        input_bytes=len(payload), input_sha256=hashlib.sha256(payload).hexdigest(),
        source_sha256={name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in files},
        generated_sha256={path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in generated},
        reference_command=command,
        scope='Original tab status selection and width functions, complete original ring/capsule/motion widgets, shared attention priority and original indeterminate animation block execute against small data and recording Canvas facades. The Canvas records ordered rounded quads and palette roles. Its zero caption measurement is excluded from width comparisons by using compact capsules. This covers geometry and animation values, not native scheduling, pixels or whole-GUI performance.',
    )
    (work / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print('Matched', len(cases), 'tab activity, ring and motion records:', result['output_sha256'])


if __name__ == '__main__':
    main()
