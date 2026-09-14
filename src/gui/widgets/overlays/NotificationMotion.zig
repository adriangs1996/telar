//! Disposable stack position, keyed by semantic notification identity.
const client = @import("telar-client");
const Clock = @import("../../animation/FrameClock.zig");
const Transition = @import("../../animation/Transition.zig");
const Motion = @This();

id: client.Id = .invalid,
from: f32 = 0,
to: f32 = 0,
transition: Transition = .{ .from = 0, .to = 1, .started_ns = 0, .duration_ns = 180_000_000 },

/// Retargets from the sampled position when another card arrives or leaves.
/// Example: `const y = motion.position(target_y, clock);`
pub fn position(motion: *Motion, target: f32, clock: *Clock) f32 {
    if (motion.to != target) {
        motion.from = motion.value(clock.now_ns);
        motion.to = target;
        motion.transition.started_ns = clock.now_ns;
    }

    _ = clock.sample(motion.transition);
    return motion.value(clock.now_ns);
}

fn value(motion: Motion, now_ns: u64) f32 {
    const t = motion.transition.value(now_ns);
    return motion.from + (motion.to - motion.from) * t * t * (3 - 2 * t);
}
