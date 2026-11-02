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

from check_task_labels import function_source


reference = r'''
const std = @import("std");
const shared_model = @import("model");
const core = @import("telar-core");
const Clock = @import("animate").FrameClock;
const Center = shared_model.Center;
const Target = shared_model.NotificationTarget;
const Outcome = struct {
    id: shared_model.NotificationId = .invalid,
    changed: bool = false,
    activated: ?Target = null,
};
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
fn readText(allocator: std.mem.Allocator) ![]const u8 {
    const bytes = try allocator.alloc(u8, try read(u16));
    for (bytes) |*byte| byte.* = try read(u8);
    return bytes;
}
fn writeText(bytes: []const u8) !void {
    try write(@as(u16, @intCast(bytes.len)));
    for (bytes) |byte| try write(byte);
}
fn readTarget() !Target {
    const kind = try read(u8);
    const id = try read(u64);
    return switch (kind) {
        0 => .none,
        1 => .{ .focus_pane = @enumFromInt(id) },
        2 => .{ .select_tab = @enumFromInt(id) },
        3 => .{ .select_workspace = @enumFromInt(id) },
        else => error.InvalidTarget,
    };
}
fn writeTarget(target: Target) !void {
    try write(@as(u8, @intFromEnum(std.meta.activeTag(target))));
    const id: u64 = switch (target) {
        .none => 0,
        .focus_pane => |value| @intFromEnum(value),
        .select_tab => |value| @intFromEnum(value),
        .select_workspace => |value| @intFromEnum(value),
    };
    try write(id);
}
fn push(center: *Center, now_ns: u64, allocator: std.mem.Allocator) !shared_model.NotificationId {
    const level: shared_model.notifications.Level = @enumFromInt(try read(u8));
    const target = try readTarget();
    const duration_ns = try read(u64);
    const title = try readText(allocator);
    const message = try readText(allocator);
    const link = try readText(allocator);
    return center.push(now_ns, .{ .level = level, .target = target, .title = title, .message = message, .link = link, .duration_ns = duration_ns });
}
fn operate(center: *Center, operation: u8, now_ns: u64, allocator: std.mem.Allocator) !Outcome {
    return switch (operation) {
        0 => blk: {
            center.* = .{ .next_id = try read(u64) };
            break :blk .{};
        },
        1 => .{ .id = try push(center, now_ns, allocator) },
        2 => .{ .changed = center.advance(now_ns) },
        3 => .{ .changed = center.dismiss(@enumFromInt(try read(u64)), now_ns) },
        4 => .{ .activated = center.activate(@enumFromInt(try read(u64)), now_ns) },
        5 => .{},
        else => error.InvalidOperation,
    };
}
__VISIBILITY__
fn snapshot(center: *const Center, outcome: Outcome, now_ns: u64, interval_ns: u64) !void {
    try write(@as(u64, @intFromEnum(outcome.id)));
    try write(@as(u8, @intFromBool(outcome.changed)));
    try write(@as(u8, @intFromBool(outcome.activated != null)));
    try writeTarget(outcome.activated orelse .none);
    try write(center.count);
    var clock: Clock = .{ .now_ns = now_ns, .interval_ns = interval_ns };
    for (0..center.count) |index| {
        const item = center.itemAt(index).?;
        try write(@as(u64, @intFromEnum(item.id)));
        try write(@as(u8, @intFromEnum(item.level)));
        try writeTarget(item.target);
        try write(@as(u8, @intFromEnum(item.phase)));
        try write(item.transition_position_ns);
        try write(item.transition_updated_ns);
        try write(item.expires_at_ns);
        try write(visibility(item, null));
        try write(visibility(item, &clock));
        try write(@as(u8, @intFromBool(item.clickable())));
        try writeText(item.title());
        try writeText(item.message());
        try writeText(item.link());
        try writeText(item.linkHost());
    }
    const deadline = center.nextDeadline(now_ns, interval_ns);
    try write(@as(u8, @intFromBool(deadline != null)));
    try write(deadline orelse 0);
}
pub fn main() !void {
    var center: Center = .{};
    while (true) {
        const operation = getchar();
        if (operation < 0) return;
        const now_ns = try read(u64);
        const interval_ns = try read(u64);
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const outcome = try operate(&center, @intCast(operation), now_ns, arena.allocator());
        try snapshot(&center, outcome, now_ns, interval_ns);
    }
}
'''


model_facade = r'''
pub const notifications = @import("notifications/notifications.zig");
pub const Center = @import("notifications/Center.zig");
pub const NotificationItem = @import("notifications/NotificationItem.zig");
pub const NotificationInput = @import("notifications/NotificationInput.zig");
pub const NotificationId = notifications.Id;
pub const NotificationTarget = notifications.Target;
pub const NotificationPublication = struct { id: NotificationId, notifications_revision: u64 };
pub const NotificationChange = struct { notifications_revision: u64 };
pub const NotificationActivation = struct { target: NotificationTarget, notifications_revision: u64 };
'''


def prepare_sources(root, work):
    names = [
        'max_notification_title_bytes', 'max_notification_message_bytes',
        'max_notification_link_bytes', 'default_notification_duration_ms',
    ]
    types = (root / 'src/core/schema/types.zig').read_text()
    core = work / 'core'
    core.mkdir()
    declarations = [re.search(rf'^pub const {name}[^\n]+;$', types, re.MULTILINE).group(0) for name in names]
    (core / 'types.zig').write_text('\n'.join(declarations) + '\n')
    aliases = '\n'.join(f'pub const {name} = @import("types.zig").{name};' for name in names)
    identities = '\n'.join(f'pub const {name} = enum(u64) {{ invalid = 0, _ }};' for name in ['PaneId', 'TabId', 'WorkspaceId'])
    (core / 'core.zig').write_text(aliases + '\n' + identities + '\npub const notification_link = @import("notification_link.zig");\n')
    shutil.copy2(root / 'src/core/schema/notification_link.zig', core / 'notification_link.zig')
    model = work / 'model'
    (model / 'notifications').mkdir(parents=True)
    (model / 'state').mkdir()
    for source in (root / 'src/model/notifications').glob('*.zig'):
        shutil.copy2(source, model / 'notifications' / source.name)
    (model / 'model.zig').write_text(model_facade)
    (model / 'state/ClientModel.zig').write_text('notification_center: @import("../notifications/Center.zig") = .{},\nnotifications_revision: u64 = 0,\n')


def prepare(root, work):
    prepare_sources(root, work)
    core = work / 'core'
    model = work / 'model'
    visibility = function_source((root / 'src/gui/widgets/overlays/Notifications.zig').read_text(), 'visibility')
    (work / 'probe.zig').write_text(reference.replace('__VISIBILITY__', visibility))
    command = [
        'zig', 'build-exe', '-O', 'ReleaseSafe', '-lc',
        '--dep', 'model', '--dep', 'telar-core', '--dep', 'animate', f'-Mroot={work / "probe.zig"}',
        '--dep', 'telar-core', f'-Mmodel={model / "model.zig"}',
        f'-Mtelar-core={core / "core.zig"}', f'-Manimate={root / "lib/animate/root.zig"}',
        f'-femit-bin={work / "original"}',
    ]
    with (work / 'reference-build.log').open('w') as output:
        subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, check=True)
    return command


maximum_time = 2**64 - 1
transition_ns = 200_000_000
frame_interval_ns = 16_000_000


def text(value):
    payload = value.encode() if isinstance(value, str) else value
    return struct.pack('<H', len(payload)) + payload


def request(operation, now, payload=b'', interval=frame_interval_ns):
    return struct.pack('<BQQ', operation, now, interval) + payload


def push(now, title='Agent needs input', message='Agent in pane 1 is waiting for input', link='', level=2, kind=1, identity=1, duration=4_000_000_000):
    payload = struct.pack('<BBQQ', level, kind, identity, duration)
    payload += text(title) + text(message) + text(link)
    return request(1, now, payload)


def fixtures():
    for seed in [0, 1, maximum_time - 1, maximum_time]:
        yield request(0, 0, struct.pack('<Q', seed))
        for index in range(6):
            yield push(index, title=f'Notice {index}', kind=index % 4, identity=index + 1)
        for now in [0, 1, transition_ns//2, transition_ns-1, transition_ns, 4_200_000_000, 4_400_000_000]:
            yield request(5, now)
            yield request(2, now)
    titles = ['', 'Agent needs input', 'a'*96, 'a'*95+'é', 'a'*97, b'\xc0\x80', '👩🏽\u200d💻'*24, 'a\0b']
    messages = ['', 'A short message', '漢字'*190, b'bad\xffmessage', 'a'*513, ' \r\n last\tline\n']
    links = ['', 'https://auth.example/login?code=abc#step', 'https://'+'a'*1016, 'https://'+'a'*1017, 'http://example.test/', 'https://user@example.test/']
    for index, title in enumerate(titles):
        for duration in [0, 1, 4_000_000_000, maximum_time]:
            for start in [0, maximum_time-transition_ns//2]:
                yield request(0, start, struct.pack('<Q', 1))
                yield push(start, title=title, message=messages[index % len(messages)], link=links[index % len(links)], duration=duration, level=index % 4, kind=index % 4)
                for elapsed in [0, 1, transition_ns//2, transition_ns-1, transition_ns, transition_ns+1, 4_200_000_000, 4_400_000_000]:
                    now = min(maximum_time, start + elapsed)
                    yield request(5, now, interval=1 if index % 2 else maximum_time)
                    yield request(2, now)
    yield request(0, 0, struct.pack('<Q', 1))
    yield push(0)
    yield push(100_000_000)
    yield request(2, transition_ns)
    yield push(transition_ns)
    yield request(4, 250_000_000, struct.pack('<Q', 1))
    yield request(4, 250_000_000, struct.pack('<Q', 1))
    yield push(250_000_000)
    yield request(3, 260_000_000, struct.pack('<Q', 2))
    yield request(2, 500_000_000)
    generator = random.Random(0x7E1A4)
    now = 0
    for index in range(6000):
        now = min(maximum_time, now + generator.choice([0, 1, 16_000_000, 120_000_000, 1_000_000_000, 5_000_000_000]))
        operation = generator.choices([0, 1, 2, 3, 4, 5], weights=[1, 8, 8, 2, 2, 4])[0]
        if operation == 0:
            now = generator.choice([0, maximum_time-generator.randrange(1_000_000_000)])
            yield request(0, now, struct.pack('<Q', generator.choice([0, 1, maximum_time-2])))
        elif operation == 1:
            title = generator.choice(titles)
            yield push(now, title, generator.choice(messages), generator.choice(links), generator.randrange(4), generator.randrange(4), generator.randrange(1, 8), generator.choice([0, 1, 500_000_000, 4_000_000_000, 7_000_000_000, maximum_time]))
        else:
            payload = struct.pack('<Q', generator.choice([0, 1, 2, 3, 4, maximum_time, maximum_time-1])) if operation in [3, 4] else b''
            yield request(operation, now, payload, generator.choice([1, frame_interval_ns, transition_ns, maximum_time]))


def run(binary, payload, work, name):
    result = subprocess.run([binary], input=payload, capture_output=True, timeout=180)
    (work / (name+'.bin')).write_bytes(result.stdout)
    (work / (name+'-stderr.log')).write_bytes(result.stderr)
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
    cases = list(fixtures())
    payload = b''.join(cases)
    (work / 'input.bin').write_bytes(payload)
    expected = run(work / 'original', payload, work, 'original')
    actual = run(options.build_dir.resolve() / 'gui-notification-center-probe', payload, work, 'cpp')
    if expected != actual:
        offset = next((index for index, pair in enumerate(zip(expected, actual)) if pair[0] != pair[1]), min(len(expected), len(actual)))
        raise RuntimeError(f'Notification center mismatch at output byte {offset}: original={len(expected)}, cpp={len(actual)}')
    sources = [
        root / 'src/gui/widgets/overlays/Notifications.zig', root / 'src/core/schema/notification_link.zig',
        root / 'src/core/schema/types.zig', Path(__file__),
        root / 'services/gui-cpp/application/notification_center.hpp',
        root / 'services/gui-cpp/application/notification_item.hpp',
        root / 'services/gui-cpp/core/smoothstep.hpp',
        root / 'services/gui-cpp/tools/notification_center_probe.cpp',
        root / 'services/desktop-mode/telar_client/serializers/telar_messages.hpp',
    ]
    sources += sorted((root / 'src/model/notifications').glob('*.zig'))
    sources += sorted((root / 'lib/animate').rglob('*.zig'))
    result = dict(
        recorded_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        operations=len(cases), input_bytes=len(payload), input_sha256=hashlib.sha256(payload).hexdigest(),
        output_bytes=len(actual), output_sha256=hashlib.sha256(actual).hexdigest(),
        source_sha256={str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources},
        generated_sha256={str(path.relative_to(work)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(work.rglob('*.zig'))},
        reference_command=command,
        scope='Unchanged original Center, NotificationItem, notification types and UTF-8/identity helpers execute over a small ClientModel/core facade. The unchanged original visibility helper uses the real FrameClock. The stream compares every retained payload, target, phase, transition timestamp, expiry, stored/fresh opacity, action result and next deadline after each operation. This does not cover native layout, delivery, sounds or full GUI parity.',
    )
    (work / 'result.json').write_text(json.dumps(result, indent=2)+'\n')
    print('Matched', len(cases), 'notification operations:', result['output_sha256'])


if __name__ == '__main__':
    main()
