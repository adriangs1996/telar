const client = @import("telar-client");
const std = @import("std");
const Target = @import("CursorTarget.zig");
const Clock = @This();

target: Target = .{},
config: client.GuiCursor = .{},
focused: bool = true,
started_ns: u64 = 0,

/// Changes reset the phase; the source remains an owned semantic value.
/// Example: `clock.observe(target, now_ns);`
pub fn observe(self: *Clock, target: Target, now_ns: u64) void {
    if (!std.meta.eql(self.target, target)) {
        self.target = target;
        self.reset(now_ns);
    }
}

/// Input and focus restart a visible phase. Example: `clock.reset(now_ns);`
pub fn reset(self: *Clock, now_ns: u64) void {
    self.started_ns = now_ns;
}

pub fn shown(self: *const Clock, now_ns: u64) bool {
    if (!self.blinks()) {
        return true;
    }

    return ((now_ns -| self.started_ns) / self.interval()) % 2 == 0;
}

/// Zero parks the native timer. Late wakeups fold missed phases.
/// Example: `const delay_ms = clock.wakeupAfter(now_ns);`
pub fn wakeupAfter(self: *const Clock, now_ns: u64) u32 {
    if (!self.blinks()) {
        return 0;
    }

    const remaining = self.interval() - (now_ns -| self.started_ns) % self.interval();
    // SAFETY: unsigned divCeil has a fixed nonzero divisor, ns_per_ms.
    return @intCast(std.math.divCeil(u64, remaining, std.time.ns_per_ms) catch unreachable);
}

fn blinks(self: *const Clock) bool {
    const cursor = self.target.cursor;
    return self.focused and cursor.visible and cursor.appearance.blink and
        (cursor.appearance.shape != .default or self.config.blink);
}

fn interval(self: *const Clock) u64 {
    return @as(u64, self.config.blink_interval_ms) * std.time.ns_per_ms;
}
