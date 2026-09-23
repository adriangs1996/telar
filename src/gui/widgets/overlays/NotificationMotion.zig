//! Disposable stack position, keyed by semantic notification identity.
const data = @import("model");
const client = @import("telar-client");
const Clock = @import("../../animation/FrameClock.zig");
const Transition = @import("../../animation/Transition.zig");
const Motion = @This();

id: data.notifications.Id = .invalid,
from: f32 = 0,
to: f32 = 0,
transition: Transition = .{ .from = 0, .to = 1, .started_ns = 0, .duration_ns = 180_000_000 },

/// Retargets from the sampled position when another card arrives or leaves.
/// Example: `const y = motion.position(target_y, clock);`
pub fn position(self: *Motion, target: f32, clock: *Clock) f32 {
    if (self.to != target) {
        self.from = self.value(clock.now_ns);
        self.to = target;
        self.transition.started_ns = clock.now_ns;
    }

    _ = clock.sample(self.transition);
    return self.value(clock.now_ns);
}

fn value(self: Motion, now_ns: u64) f32 {
    const t = self.transition.value(now_ns);
    return self.from + (self.to - self.from) * t * t * (3 - 2 * t);
}
