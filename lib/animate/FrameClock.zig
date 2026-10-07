//! One frame timestamp and one coalesced deadline for all visible widgets.
//! The window driver alone owns the timer; drawing never starts a worker.
const std = @import("std");
const Transition = @import("Transition.zig");
const Clock = @This();

/// The cadence of a clock no host has paced yet, rounded up so a frame asked
/// for one interval ahead never lands before the next 60 Hz frame.
pub const default_interval_ns = std.time.ns_per_s / 60 + 1;

now_ns: u64 = 0,
/// How far ahead a running transition asks for its next frame: the window's
/// frame interval, so motion advances once per presented frame at the
/// display's rate.
interval_ns: u64 = default_interval_ns,
deadline_ns: ?u64 = null,
waiting_for_frame: bool = false,

/// Discards the previous frame's requests. Hidden widgets need no cleanup.
/// Example: `clock.begin(now_ns);`
pub fn begin(self: *Clock, now_ns: u64) void {
    self.now_ns = @max(self.now_ns, now_ns);
    self.deadline_ns = null;
    self.waiting_for_frame = false;
}

/// Coalesces requests; a later widget cannot postpone an earlier deadline.
/// Example: `clock.requestAt(next_sprite_ns);`
pub fn requestAt(self: *Clock, deadline_ns: u64) void {
    self.deadline_ns = if (self.deadline_ns) |previous| @min(previous, deadline_ns) else deadline_ns;
}

/// Samples a transition and requests another frame only while it is active.
/// Example: `const opacity = clock.sample(transition);`
pub fn sample(self: *Clock, transition: Transition) f32 {
    if (self.now_ns < transition.started_ns) {
        self.requestAt(transition.started_ns);
    } else if (!transition.finished(self.now_ns)) {
        self.requestAt(@min(self.now_ns +| self.interval_ns, transition.started_ns +| transition.duration_ns));
    }

    return transition.value(self.now_ns);
}

/// Selects a periodic sprite/pulse step and wakes at its next boundary.
/// Example: `const sprite_index = clock.step(100 * std.time.ns_per_ms) % 8;`
pub fn step(self: *Clock, interval_ns: u64) u64 {
    std.debug.assert(interval_ns > 0);
    self.requestAt(self.now_ns +| (interval_ns - self.now_ns % interval_ns));
    return self.now_ns / interval_ns;
}

/// Example: `const needs_frame = clock.due(now_ns);`
pub fn due(self: *const Clock, now_ns: u64) bool {
    return if (self.deadline_ns) |deadline| now_ns >= deadline else false;
}

/// Hands due work to the host's retained dirty flag. A compositor may defer
/// drawing indefinitely, so the timer parks until preparation actually begins.
/// Example: `if (clock.requestPreparation(now_ns)) requestDraw();`
pub fn requestPreparation(self: *Clock, now_ns: u64) bool {
    if (!self.due(now_ns)) {
        return false;
    }

    self.waiting_for_frame = true;
    return true;
}

/// Zero parks the host timer; overdue work wakes once as soon as possible.
/// Example: `const delay_ms = clock.wakeupAfter(now_ns);`
pub fn wakeupAfter(self: *const Clock, now_ns: u64) u32 {
    if (self.waiting_for_frame) {
        return 0;
    }

    const deadline = self.deadline_ns orelse return 0;
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
