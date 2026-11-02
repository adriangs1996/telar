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

from check_notification_center import prepare_sources, run


canvas_source = r'''
const data = @import("model");
const Rect = @import("gfx").Rect;
const Clock = @import("animate").FrameClock;
const Canvas = @This();
pub const Chrome = struct {
    ratio: f32,
    pub fn px(self: @This(), value: f32) f32 { return value * self.ratio; }
};
chrome: Chrome,
animation: ?*Clock,
items: []const data.NotificationItem,
heights: []const f32,
pub fn rect(_: *const Canvas, area: Rect) Rect { return area; }
pub fn height(self: *const Canvas, item: *const data.NotificationItem) f32 {
    for (self.items, self.heights) |candidate, value| {
        if (candidate.id == item.id) return value;
    }
    unreachable;
}
'''

card_source = r'''
const data = @import("model");
const Rect = @import("gfx").Rect;
const Canvas = @import("../Canvas.zig");
item: *const data.NotificationItem,
bounds: Rect,
clip: Rect,
opacity: f32 = 1,
pub fn measure(self: *@This(), canvas: *Canvas) !void {
    self.bounds.height = canvas.height(self.item);
}
'''

client_source = r'''
const core = @import("telar-core");
const data = @import("model");
const Rect = @import("gfx").Rect;
pub const Layout = struct {
    visible: core.PaneId,
    pub fn find(self: @This(), id: core.PaneId) ?usize {
        return if (self.visible == id) 0 else null;
    }
};
pub const Projection = struct {
    geometry: struct { area: Rect },
    notifications: *const data.Center,
    layout: ?Layout,
};
'''

reference_source = r'''
const std = @import("std");
const data = @import("model");
const client = @import("telar-client");
const Clock = @import("animate").FrameClock;
const Rect = @import("gfx").Rect;
const Canvas = @import("widgets/Canvas.zig");
const Stack = @import("widgets/overlays/Notifications.zig");
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
fn readRect() !Rect {
    const x = try read(f32);
    const y = try read(f32);
    const width = try read(f32);
    return .{ .x = x, .y = y, .width = width, .height = try read(f32) };
}
fn readItem() !data.NotificationItem {
    const id: data.NotificationId = @enumFromInt(try read(u64));
    const phase: @FieldType(data.NotificationItem, "phase") = @enumFromInt(try read(u8));
    const position = try read(u64);
    const updated = try read(u64);
    const expires = try read(u64);
    const kind = try read(u8);
    const target_id = try read(u64);
    const target: data.NotificationTarget = switch (kind) {
        0 => .none,
        1 => .{ .focus_pane = @enumFromInt(target_id) },
        2 => .{ .select_tab = @enumFromInt(target_id) },
        3 => .{ .select_workspace = @enumFromInt(target_id) },
        else => return error.InvalidTarget,
    };
    return .{ .id = id, .level = .info, .title_len = 0, .message_len = 0, .phase = phase, .transition_position_ns = position, .transition_updated_ns = updated, .expires_at_ns = expires, .target = target };
}
fn frame(stack: *Stack) !void {
    var clock: Clock = .{ .now_ns = try read(u64) };
    const host = try readRect();
    const ratio = try read(f32);
    const visible = try read(u64);
    const count = try read(u8);
    if (count > data.notifications.max_items) return error.CapacityExceeded;
    var items: [data.notifications.max_items]data.NotificationItem = undefined;
    var heights: [data.notifications.max_items]f32 = undefined;
    for (0..count) |index| {
        items[index] = try readItem();
        heights[index] = try read(f32);
    }
    var center: data.Center = .{ .count = count };
    for (items[0..count], 0..) |value, index| center.items[index] = value;
    const projection: client.Projection = .{
        .geometry = .{ .area = host }, .notifications = &center,
        .layout = if (visible == 0) null else .{ .visible = @enumFromInt(visible) },
    };
    var canvas: Canvas = .{ .chrome = .{ .ratio = ratio }, .animation = &clock, .items = items[0..count], .heights = heights[0..count] };
    const cards = try stack.prepare(&canvas, projection);
    try write(@as(u8, @intCast(cards.len)));
    for (cards.storage[0..cards.len]) |card| {
        var index: usize = 0;
        while (items[index].id != card.item.id) : (index += 1) {}
        try write(@as(u8, @intCast(index)));
        try write(@as(u64, @intFromEnum(card.item.id)));
        try write(card.bounds.x);
        try write(card.bounds.y);
        try write(card.bounds.width);
        try write(card.bounds.height);
        try write(card.opacity);
    }
}
pub fn main() !void {
    var stack: Stack = .{};
    while (true) {
        const operation = getchar();
        switch (operation) {
            -1 => return,
            0 => stack = .{},
            1 => try frame(&stack),
            else => return error.InvalidOperation,
        }
    }
}
'''


def prepare(root, work):
    prepare_sources(root, work)
    widgets = work / 'widgets'
    overlays = widgets / 'overlays'
    overlays.mkdir(parents=True)
    shutil.copy2(root / 'src/gui/widgets/overlays/Notifications.zig', overlays / 'Notifications.zig')
    shutil.copy2(root / 'src/gui/widgets/GenericWidgetList.zig', widgets / 'GenericWidgetList.zig')
    hits = (root / 'src/gui/widgets/overlays/NotificationHits.zig').read_text()
    (overlays / 'NotificationHits.zig').write_text(re.search(r'^pub const max_visible[^\n]+;$', hits, re.MULTILINE).group(0) + '\n')
    (overlays / 'NotificationCard.zig').write_text(card_source)
    (widgets / 'Canvas.zig').write_text(canvas_source)
    (work / 'client.zig').write_text(client_source)
    (work / 'gfx.zig').write_text('pub const Rect = struct { x: f32, y: f32, width: f32, height: f32 };\n')
    (work / 'probe.zig').write_text(reference_source)
    command = [
        'zig', 'build-exe', '-O', 'ReleaseSafe', '-lc',
        '--dep', 'model', '--dep', 'telar-core', '--dep', 'animate', '--dep', 'gfx', '--dep', 'telar-client', f'-Mroot={work / "probe.zig"}',
        '--dep', 'telar-core', f'-Mmodel={work / "model/model.zig"}',
        f'-Mtelar-core={work / "core/core.zig"}', f'-Manimate={root / "lib/animate/root.zig"}', f'-Mgfx={work / "gfx.zig"}',
        '--dep', 'telar-core', '--dep', 'model', '--dep', 'gfx', f'-Mtelar-client={work / "client.zig"}',
        f'-femit-bin={work / "original"}',
    ]
    with (work / 'reference-build.log').open('w') as output:
        subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, check=True)
    return command


transition_ns = 200_000_000
maximum_time = 2**64 - 1
scales = [0.5, 0.8, 1, 1.25, 1.5, 2]


def item(identity, phase=1, position=transition_ns, updated=0, expires=maximum_time, kind=0, target=1, height=100):
    return struct.pack('<QBQQQBQf', identity, phase, position, updated, expires, kind, target, height)


def frame(now, items, host=(100, 50, 800, 500), ratio=1, visible=0):
    return struct.pack('<BQ5fQB', 1, now, *host, ratio, visible, len(items)) + b''.join(items)


def fixtures():
    yield b'\0'
    now = 1_000_000_000
    for ratio in scales:
        yield b'\0'
        first = item(1, height=100 * ratio)
        second = item(2, phase=0, position=0, updated=now, kind=1, target=42, height=130 * ratio)
        yield frame(now, [first], ratio=ratio)
        for elapsed in [0, 1, 16_000_000, 90_000_000, 179_999_999, 180_000_000, 199_999_999, transition_ns]:
            yield frame(now + elapsed, [second, first], ratio=ratio)
        for elapsed in [210_000_000, 250_000_000, 300_000_000, 400_000_000]:
            yield frame(now + elapsed, [second, first], ratio=ratio, visible=42)
        for width in [191, 192, 192.001, 359.9, 392, 800]:
            for height in [95, 96, 97, 150, 500]:
                yield frame(now + transition_ns, [second, first], host=(-0.25, 0.75, width * ratio, height * ratio), ratio=ratio)
    generator = random.Random(0x7E1A57AC)
    for episode in range(96):
        yield b'\0'
        now = generator.choice([0, 1_000_000_000, maximum_time - 8_000_000_000])
        for index in range(128):
            now = min(maximum_time, now + generator.choice([0, 1, 8_333_333, 16_000_000, 90_000_000, transition_ns, 500_000_000]))
            ratio = generator.choice(scales)
            identities = generator.sample(range(1, 13), generator.randrange(5))
            items = [item(identity, phase=generator.randrange(3), position=generator.choice([0, 1, 90_000_000, transition_ns - 1, transition_ns]), updated=max(0, now - generator.choice([0, 1, 90_000_000, transition_ns])), kind=generator.randrange(4), target=generator.randrange(1, 5), height=generator.choice([64, 90, 100, 130, 180]) * ratio) for identity in identities]
            host = (generator.choice([-0.25, 0, 50.125, 100.75]), generator.choice([0, 0.25, 50.125]), generator.choice([191, 192, 300, 392, 800]) * ratio, generator.choice([95, 96, 150, 500]) * ratio)
            yield frame(now, items, host=host, ratio=ratio, visible=generator.randrange(5))


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
    actual = run(options.build_dir.resolve() / 'gui-notification-stack-probe', payload, work, 'cpp')
    if expected != actual:
        offset = next((index for index, pair in enumerate(zip(expected, actual)) if pair[0] != pair[1]), min(len(expected), len(actual)))
        raise RuntimeError(f'Notification stack mismatch at output byte {offset}: original={len(expected)}, cpp={len(actual)}')
    sources = [
        root / 'src/gui/widgets/overlays/Notifications.zig', root / 'src/gui/widgets/overlays/NotificationHits.zig',
        root / 'src/gui/widgets/GenericWidgetList.zig', Path(__file__), Path(__file__).with_name('check_notification_center.py'),
        root / 'services/gui-cpp/tools/notification_stack_probe.cpp', root / 'services/gui-cpp/presentation/notification_stack.hpp',
        root / 'services/gui-cpp/presentation/notification_geometry.hpp', root / 'services/gui-cpp/application/notification_item.hpp',
    ]
    sources += sorted((root / 'src/model/notifications').glob('*.zig'))
    sources += sorted((root / 'lib/animate').rglob('*.zig'))
    result = dict(
        recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(), operations=len(cases),
        frames=sum(case[0] == 1 for case in cases), input_bytes=len(payload), input_sha256=hashlib.sha256(payload).hexdigest(),
        output_bytes=len(actual), output_sha256=hashlib.sha256(actual).hexdigest(),
        source_sha256={str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources},
        generated_sha256={str(path.relative_to(work)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(work.rglob('*.zig'))},
        reference_command=command,
        scope='Unchanged original Notifications.prepare, visibility, targetVisible and Motion with the real notification items, FrameClock, Transition and GenericWidgetList. Canvas geometry, pane lookup and premeasured card heights are injected. Each retained frame compares painter order, identity, four physical bounds and opacity byte for byte. Covers arrival, removal, retargeting, hidden panes, six densities, fractional origins, capacity and fit limits, clock saturation and reversal. Card text measurement, timer scheduling and raster output are outside this oracle.',
    )
    (work / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print('Matched', result['frames'], 'notification stack frames:', result['output_sha256'])


if __name__ == '__main__':
    main()
