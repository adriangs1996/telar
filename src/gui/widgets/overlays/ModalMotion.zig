//! One disposable entrance transition for the active modal generation.
const std = @import("std");
const animate = @import("animate");
const FrameClock = animate.FrameClock;
const Transition = animate.Transition;
const ModalMotion = @This();

pub const duration_ns = 220 * std.time.ns_per_ms;

generation: ?u64 = null,
transition: Transition = .{ .from = 1, .to = 1, .started_ns = 0, .duration_ns = 0 },

/// A generation opens once; query results and inspector changes keep its phase.
/// Hidden and static compositions request no animation frames.
/// Example: `const reveal = motion.sample(prompt_generation, canvas.animation);`
pub fn sample(self: *ModalMotion, generation: ?u64, animation: ?*FrameClock) f32 {
    const current_generation = generation orelse {
        self.* = .{};
        return 1;
    };
    const clock = animation orelse {
        self.* = .{ .generation = current_generation };
        return 1;
    };

    if (self.generation != current_generation) {
        self.generation = current_generation;
        self.transition = .{ .from = 0, .to = 1, .started_ns = clock.now_ns, .duration_ns = duration_ns };
    }

    const remaining = 1 - clock.sample(self.transition);
    return 1 - remaining * remaining * remaining;
}
