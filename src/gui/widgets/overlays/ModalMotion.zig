//! One disposable entrance transition for the active modal generation.
const std = @import("std");
const FrameClock = @import("../../animation/FrameClock.zig");
const Transition = @import("../../animation/Transition.zig");
const ModalMotion = @This();

pub const duration_ns = 220 * std.time.ns_per_ms;

generation: ?u64 = null,
transition: Transition = .{ .from = 1, .to = 1, .started_ns = 0, .duration_ns = 0 },

/// A generation opens once; query results and inspector changes keep its phase.
/// Hidden and static compositions request no animation frames.
/// Example: `const reveal = motion.sample(prompt_generation, canvas.animation);`
pub fn sample(motion: *ModalMotion, generation: ?u64, animation: ?*FrameClock) f32 {
    const current_generation = generation orelse {
        motion.* = .{};
        return 1;
    };
    const clock = animation orelse {
        motion.* = .{ .generation = current_generation };
        return 1;
    };

    if (motion.generation != current_generation) {
        motion.generation = current_generation;
        motion.transition = .{ .from = 0, .to = 1, .started_ns = clock.now_ns, .duration_ns = duration_ns };
    }

    const remaining = 1 - clock.sample(motion.transition);
    return 1 - remaining * remaining * remaining;
}

test "history entrance keeps its phase across updates to the same prompt" {
    var motion: ModalMotion = .{};
    var clock: FrameClock = .{};
    clock.begin(10 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(f32, 0), motion.sample(7, &clock));
    try std.testing.expectEqual(clock.now_ns + FrameClock.frame_interval_ns, clock.deadline_ns.?);

    clock.begin(10 * std.time.ns_per_s + duration_ns / 2);
    try std.testing.expectEqual(@as(f32, 0.875), motion.sample(7, &clock));
    try std.testing.expectEqual(@as(f32, 0.875), motion.sample(7, &clock));

    clock.begin(10 * std.time.ns_per_s + duration_ns);
    try std.testing.expectEqual(@as(f32, 1), motion.sample(7, &clock));
    try std.testing.expectEqual(@as(?u64, null), clock.deadline_ns);
}

test "history entrance closes without a deadline and reopens from its origin" {
    var motion: ModalMotion = .{};
    var clock: FrameClock = .{};
    clock.begin(0);
    _ = motion.sample(0, &clock);

    clock.begin(duration_ns / 2);
    try std.testing.expectEqual(@as(f32, 1), motion.sample(null, &clock));
    try std.testing.expectEqual(@as(?u64, null), clock.deadline_ns);
    try std.testing.expectEqual(@as(?u64, null), motion.generation);

    clock.begin(duration_ns);
    try std.testing.expectEqual(@as(f32, 0), motion.sample(0, &clock));
    try std.testing.expect(clock.deadline_ns != null);
}

test "history entrance restarts for a replacement generation and folds late frames" {
    var motion: ModalMotion = .{};
    var clock: FrameClock = .{};
    clock.begin(0);
    _ = motion.sample(1, &clock);

    clock.begin(duration_ns / 2);
    try std.testing.expectEqual(@as(f32, 0), motion.sample(2, &clock));

    clock.begin(60 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(f32, 1), motion.sample(2, &clock));
    try std.testing.expectEqual(@as(?u64, null), clock.deadline_ns);
}

test "static history composition is fully visible and cannot defer an entrance" {
    var motion: ModalMotion = .{};
    var clock: FrameClock = .{};
    try std.testing.expectEqual(@as(f32, 1), motion.sample(4, null));

    clock.begin(std.time.ns_per_s);
    try std.testing.expectEqual(@as(f32, 1), motion.sample(4, &clock));
    try std.testing.expectEqual(@as(?u64, null), clock.deadline_ns);

    try std.testing.expectEqual(@as(f32, 0), motion.sample(5, &clock));
    try std.testing.expectEqual(@as(f32, 1), motion.sample(5, null));

    clock.begin(std.time.ns_per_s + duration_ns / 2);
    try std.testing.expectEqual(@as(f32, 1), motion.sample(5, &clock));
    try std.testing.expectEqual(@as(?u64, null), clock.deadline_ns);
}
