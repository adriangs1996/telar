//! One attachment's disposable progress interpolation; never borrows its pane.
const data = @import("model");
const std = @import("std");
const client = @import("telar-client");
const FrameClock = @import("../animation/FrameClock.zig");
const Transition = @import("../animation/Transition.zig");
const ProgressMotion = @This();

pub const duration_ns = 240 * std.time.ns_per_ms;

key: data.AgentKey,
from: f32 = 0,
to: f32 = 0,
known: bool = false,
transition: Transition = .{ .from = 0, .to = 1, .started_ns = 0, .duration_ns = 0 },

/// Retargets from the visible eased value, folding any frames that were missed.
/// Example: `const fraction = motion.sample(pane, &clock);`
pub fn sample(self: *ProgressMotion, pane: *const data.Pane, clock: *FrameClock) f32 {
    const target = reported(pane);
    if (pane.progress_state != .set or pane.progress_percent == null or !self.known) {
        self.from = target;
        self.to = target;
        self.known = pane.progress_percent != null and pane.progress_state != .indeterminate;
        self.transition.duration_ns = 0;
        return target;
    }

    if (target != self.to) {
        self.from = self.value(self.transition.value(clock.now_ns));
        self.to = target;
        self.transition.started_ns = clock.now_ns;
        self.transition.duration_ns = if (self.from == target) 0 else duration_ns;
    }

    return self.value(clock.sample(self.transition));
}

/// Unknown percentages have no determinate fill; bounds remain valid for all u8 values.
/// Example: `const fraction = ProgressMotion.reported(pane);`
pub fn reported(pane: *const data.Pane) f32 {
    return @as(f32, @floatFromInt(@min(pane.progress_percent orelse 0, 100))) / 100;
}

fn value(self: ProgressMotion, phase: f32) f32 {
    if (phase >= 1) {
        return self.to;
    }

    const remaining = 1 - phase;
    const eased = 1 - remaining * remaining * remaining;
    return std.math.clamp(self.from + (self.to - self.from) * eased, 0, 1);
}
