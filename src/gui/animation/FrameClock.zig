//! One frame timestamp and one coalesced deadline for all visible widgets.
//! The window driver alone owns the timer; drawing never starts a worker.
const std = @import("std");
const Transition = @import("Transition.zig");
const Clock = @This();

pub const frame_interval_ns = std.time.ns_per_s / 60 + 1;

now_ns: u64 = 0,
deadline_ns: ?u64 = null,
waiting_for_frame: bool = false,

/// Discards the previous frame's requests. Hidden widgets need no cleanup.
/// Example: `clock.begin(now_ns);`
pub fn begin(clock: *Clock, now_ns: u64) void {
    clock.now_ns = @max(clock.now_ns, now_ns);
    clock.deadline_ns = null;
    clock.waiting_for_frame = false;
}

/// Coalesces requests; a later widget cannot postpone an earlier deadline.
/// Example: `clock.requestAt(next_sprite_ns);`
pub fn requestAt(clock: *Clock, deadline_ns: u64) void {
    clock.deadline_ns = if (clock.deadline_ns) |previous| @min(previous, deadline_ns) else deadline_ns;
}

/// Samples a transition and requests another frame only while it is active.
/// Example: `const opacity = clock.sample(transition);`
pub fn sample(clock: *Clock, transition: Transition) f32 {
    if (clock.now_ns < transition.started_ns) {
        clock.requestAt(transition.started_ns);
    } else if (!transition.finished(clock.now_ns)) {
        clock.requestAt(@min(clock.now_ns +| frame_interval_ns, transition.started_ns +| transition.duration_ns));
    }

    return transition.value(clock.now_ns);
}

/// Selects a periodic sprite/pulse step and wakes at its next boundary.
/// Example: `const sprite_index = clock.step(100 * std.time.ns_per_ms) % 8;`
pub fn step(clock: *Clock, interval_ns: u64) u64 {
    std.debug.assert(interval_ns > 0);
    clock.requestAt(clock.now_ns +| (interval_ns - clock.now_ns % interval_ns));
    return clock.now_ns / interval_ns;
}

/// Example: `const needs_frame = clock.due(now_ns);`
pub fn due(clock: *const Clock, now_ns: u64) bool {
    return if (clock.deadline_ns) |deadline| now_ns >= deadline else false;
}

/// Hands due work to the host's retained dirty flag. A compositor may defer
/// drawing indefinitely, so the timer parks until preparation actually begins.
/// Example: `if (clock.requestPreparation(now_ns)) requestDraw();`
pub fn requestPreparation(clock: *Clock, now_ns: u64) bool {
    if (!clock.due(now_ns)) {
        return false;
    }

    clock.waiting_for_frame = true;
    return true;
}

/// Zero parks the host timer; overdue work wakes once as soon as possible.
/// Example: `const delay_ms = clock.wakeupAfter(now_ns);`
pub fn wakeupAfter(clock: *const Clock, now_ns: u64) u32 {
    if (clock.waiting_for_frame) {
        return 0;
    }

    const deadline = clock.deadline_ns orelse return 0;
    const remaining = deadline -| now_ns;
    const milliseconds = remaining / std.time.ns_per_ms + @intFromBool(remaining % std.time.ns_per_ms != 0);
    return @intCast(std.math.clamp(milliseconds, 1, std.math.maxInt(u32)));
}

/// Merges optional host delays, where zero means that source is idle.
/// Example: `return FrameClock.earliest(cursor_delay, widget_delay);`
pub fn earliest(first: u32, second: u32) u32 {
    if (first == 0) {
        return second;
    }

    return if (second == 0) first else @min(first, second);
}

test "visible widgets share one earliest deadline and disappear without orphan timers" {
    var clock: Clock = .{};
    clock.begin(0);
    try std.testing.expectEqual(@as(u64, 0), clock.step(100 * std.time.ns_per_ms));
    _ = clock.step(250 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u32, 100), clock.wakeupAfter(0));
    try std.testing.expect(!clock.due(99 * std.time.ns_per_ms));
    try std.testing.expect(clock.due(100 * std.time.ns_per_ms));
    clock.begin(350 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u64, 3), clock.step(100 * std.time.ns_per_ms));
    try std.testing.expectEqual(@as(u32, 50), clock.wakeupAfter(clock.now_ns));
    clock.begin(400 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u32, 0), clock.wakeupAfter(clock.now_ns));
    try std.testing.expect(!clock.due(std.math.maxInt(u64)));
}

test "completed transitions park and overdue deadlines never become idle" {
    var clock: Clock = .{};
    const transition: Transition = .{ .from = 0, .to = 1, .started_ns = 0, .duration_ns = 200 * std.time.ns_per_ms };
    clock.begin(0);
    try std.testing.expectEqual(@as(f32, 0), clock.sample(transition));
    try std.testing.expectEqual(@as(u32, 17), clock.wakeupAfter(0));
    try std.testing.expectEqual(@as(u32, 1), clock.wakeupAfter(50 * std.time.ns_per_ms));
    clock.begin(500 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(f32, 1), clock.sample(transition));
    try std.testing.expectEqual(@as(u32, 0), clock.wakeupAfter(clock.now_ns));
    try std.testing.expectEqual(@as(u32, 0), Clock.earliest(0, 0));
    try std.testing.expectEqual(@as(u32, 17), Clock.earliest(600, 17));
    try std.testing.expectEqual(@as(u32, 17), Clock.earliest(0, 17));
    try std.testing.expectEqual(@as(u32, 600), Clock.earliest(600, 0));
}

test "a compositor which defers a requested frame does not cause timer polling" {
    var clock: Clock = .{};
    clock.begin(0);
    _ = clock.step(100 * std.time.ns_per_ms);
    try std.testing.expect(!clock.requestPreparation(50 * std.time.ns_per_ms));
    try std.testing.expect(clock.requestPreparation(100 * std.time.ns_per_ms));
    try std.testing.expect(clock.due(300 * std.time.ns_per_s));
    try std.testing.expectEqual(@as(u32, 0), clock.wakeupAfter(300 * std.time.ns_per_s));
    clock.begin(300 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(u64, 3000), clock.step(100 * std.time.ns_per_ms));
    try std.testing.expectEqual(@as(u32, 100), clock.wakeupAfter(clock.now_ns));
}

test "delayed transitions request only their start including instantaneous changes" {
    var clock: Clock = .{};
    var transition: Transition = .{ .from = 0, .to = 1, .started_ns = 10 * std.time.ns_per_s, .duration_ns = std.time.ns_per_s };
    clock.begin(0);
    try std.testing.expectEqual(@as(f32, 0), clock.sample(transition));
    try std.testing.expectEqual(@as(u32, 10_000), clock.wakeupAfter(0));
    transition.duration_ns = 0;
    clock.begin(5 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(f32, 0), clock.sample(transition));
    try std.testing.expectEqual(@as(u32, 5000), clock.wakeupAfter(clock.now_ns));
    clock.begin(transition.started_ns);
    try std.testing.expectEqual(@as(f32, 1), clock.sample(transition));
    try std.testing.expectEqual(@as(u32, 0), clock.wakeupAfter(clock.now_ns));
}
