//! A scalar transition sampled from monotonic time, independent of frame count.
const Transition = @This();

from: f32,
to: f32,
started_ns: u64,
duration_ns: u64,

/// Late presentations sample the current position, never replay missed steps.
/// Example: `const opacity = transition.value(frame.now_ns);`
pub fn value(self: Transition, now_ns: u64) f32 {
    if (now_ns < self.started_ns) {
        return self.from;
    }

    if (self.finished(now_ns)) {
        return self.to;
    }

    const progress = @as(f32, @floatFromInt(now_ns -| self.started_ns)) / @as(f32, @floatFromInt(self.duration_ns));
    return self.from + (self.to - self.from) * progress;
}

/// Example: `if (transition.finished(now_ns)) stopAnimating();`
pub fn finished(self: Transition, now_ns: u64) bool {
    return now_ns >= self.started_ns and now_ns - self.started_ns >= self.duration_ns;
}

/// Changes direction from the currently visible value without a position jump.
/// Example: `transition.retarget(0, now_ns);`
pub fn retarget(self: *Transition, target: f32, now_ns: u64) void {
    self.from = self.value(now_ns);
    self.to = target;
    self.started_ns = now_ns;
}

test "transitions fold late frames and reverse continuously" {
    const std = @import("std");
    var transition: Transition = .{ .from = 0, .to = 1, .started_ns = 100, .duration_ns = 200 };
    try std.testing.expectEqual(@as(f32, 0), transition.value(50));
    try std.testing.expectEqual(@as(f32, 0.5), transition.value(200));
    transition.retarget(0, 200);
    try std.testing.expectEqual(@as(f32, 0.5), transition.value(200));
    try std.testing.expectEqual(@as(f32, 0.25), transition.value(300));
    try std.testing.expectEqual(@as(f32, 0), transition.value(999));
    transition.duration_ns = 0;
    try std.testing.expectEqual(transition.to, transition.value(200));
}
