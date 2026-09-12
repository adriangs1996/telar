const std = @import("std");
const Config = @import("telar-client").GuiCursor;
const Target = @import("CursorTarget.zig");
const Clock = @This();

target: Target = .{},
config: Config = .{},
focused: bool = true,
started_ns: u64 = 0,

/// Changes reset the phase; the source remains an owned semantic value.
/// Example: `clock.observe(target, now_ns);`
pub fn observe(clock: *Clock, target: Target, now_ns: u64) void {
    if (!std.meta.eql(clock.target, target)) {
        clock.target = target;
        clock.reset(now_ns);
    }
}

/// Input and focus restart a visible phase. Example: `clock.reset(now_ns);`
pub fn reset(clock: *Clock, now_ns: u64) void {
    clock.started_ns = now_ns;
}

pub fn shown(clock: *const Clock, now_ns: u64) bool {
    if (!clock.blinks()) {
        return true;
    }

    return ((now_ns -| clock.started_ns) / clock.interval()) % 2 == 0;
}

/// Zero parks the native timer. Late wakeups fold missed phases.
/// Example: `const delay_ms = clock.wakeupAfter(now_ns);`
pub fn wakeupAfter(clock: *const Clock, now_ns: u64) u32 {
    if (!clock.blinks()) {
        return 0;
    }

    const remaining = clock.interval() - (now_ns -| clock.started_ns) % clock.interval();
    return @intCast(std.math.divCeil(u64, remaining, std.time.ns_per_ms) catch unreachable);
}

fn blinks(clock: *const Clock) bool {
    const cursor = clock.target.cursor;
    return clock.focused and cursor.visible and cursor.appearance.blink and
        (cursor.appearance.shape != .default or clock.config.blink);
}

fn interval(clock: *const Clock) u64 {
    return @as(u64, clock.config.blink_interval_ms) * std.time.ns_per_ms;
}

test "cursor deadlines fold late wakeups and park for hidden steady or unfocused cursors" {
    var clock: Clock = .{};
    var target: Target = .{ .pane_id = @enumFromInt(1), .cursor = .{ .visible = true } };
    clock.observe(target, 0);
    try std.testing.expect(clock.shown(599 * std.time.ns_per_ms));
    try std.testing.expect(!clock.shown(600 * std.time.ns_per_ms));
    try std.testing.expect(clock.shown(2400 * std.time.ns_per_ms));
    try std.testing.expectEqual(@as(u32, 600), clock.wakeupAfter(2400 * std.time.ns_per_ms));
    clock.reset(650 * std.time.ns_per_ms);
    try std.testing.expect(clock.shown(650 * std.time.ns_per_ms));
    clock.focused = false;
    try std.testing.expectEqual(@as(u32, 0), clock.wakeupAfter(0));
    clock.focused = true;
    target.cursor.visible = false;
    clock.observe(target, 0);
    try std.testing.expectEqual(@as(u32, 0), clock.wakeupAfter(0));
    target.cursor.visible = true;
    target.cursor.appearance.blink = false;
    clock.observe(target, 0);
    try std.testing.expectEqual(@as(u32, 0), clock.wakeupAfter(0));
}

test "application cursor style overrides GUI defaults until the VT restores default style" {
    var clock: Clock = .{ .config = .{ .blink = false } };
    var target: Target = .{ .cursor = .{ .visible = true } };
    clock.observe(target, 0);
    try std.testing.expectEqual(@as(u32, 0), clock.wakeupAfter(0));
    target.cursor.appearance.shape = .bar;
    clock.observe(target, 0);
    try std.testing.expectEqual(@as(u32, 600), clock.wakeupAfter(0));
    target.generation = 1;
    clock.observe(target, 700 * std.time.ns_per_ms);
    try std.testing.expect(clock.shown(700 * std.time.ns_per_ms));
    target.cursor.appearance.shape = .default;
    clock.observe(target, 0);
    try std.testing.expectEqual(@as(u32, 0), clock.wakeupAfter(0));
}
