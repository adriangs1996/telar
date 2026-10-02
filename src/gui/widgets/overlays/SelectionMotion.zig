//! How open the selected history row is. Moving the selection opens the row
//! it reaches while the row it left closes, so their neighbours barely move.
//! The selection itself changes at once; only the card's height follows.
const std = @import("std");
const animate = @import("animate");
const FrameClock = animate.FrameClock;
const Transition = animate.Transition;
const HistoryExpansion = @import("HistoryExpansion.zig");
const HistoryPosition = @import("HistoryPosition.zig");
const SelectionMotion = @This();

pub const duration_ns = 140 * std.time.ns_per_ms;

const settled: Transition = .{ .from = 1, .to = 1, .started_ns = 0, .duration_ns = 0 };

generation: ?u64 = null,
selected: HistoryPosition = .{ .index = 0, .id = 0 },
leaving: ?HistoryPosition = null,
/// How open the leaving row was when the selection left it.
leaving_from: f32 = 1,
transition: Transition = settled,

/// A prompt opens with its selection already open, and a page that changes
/// under the same position moves nothing, so typing never replays the
/// motion. Static compositions and finished motions request no frames.
/// Example: `const expansion = motion.sample(prompt.generation, .{ .index = selection, .id = entry.id }, canvas.animation);`
pub fn sample(self: *SelectionMotion, generation: ?u64, selected: ?HistoryPosition, animation: ?*FrameClock) HistoryExpansion {
    const current_generation = generation orelse {
        self.* = .{};
        return .{};
    };
    const row = selected orelse {
        self.* = .{};
        return .{};
    };
    const clock = animation orelse {
        self.* = .{ .generation = current_generation, .selected = row };
        return .{};
    };

    if (self.generation != current_generation) {
        self.* = .{ .generation = current_generation, .selected = row };
        return .{};
    }

    if (self.selected.index != row.index) {
        self.leaving_from = eased(self.transition.value(clock.now_ns));
        self.leaving = self.selected;
        self.selected = row;
        self.transition = .{ .from = 0, .to = 1, .started_ns = clock.now_ns, .duration_ns = duration_ns };
    } else if (self.selected.id != row.id) {
        self.selected = row;
        self.leaving = null;
        self.transition = settled;
    }

    const open = eased(clock.sample(self.transition));
    if (open >= 1) {
        self.leaving = null;
    }

    return .{
        .open = open,
        .leaving = self.leaving,
        .leaving_open = self.leaving_from * (1 - open),
    };
}

// Cubic ease-out, the curve of the modal's entrance.
fn eased(progress: f32) f32 {
    const remaining = 1 - progress;
    return 1 - remaining * remaining * remaining;
}

test "a prompt opens with its selection open and requests no frame" {
    var motion: SelectionMotion = .{};
    var clock: FrameClock = .{};
    clock.begin(std.time.ns_per_s);
    const expansion = motion.sample(3, .{ .index = 0, .id = 9 }, &clock);
    try std.testing.expectEqual(@as(f32, 1), expansion.open);
    try std.testing.expectEqual(@as(?HistoryPosition, null), expansion.leaving);
    try std.testing.expectEqual(@as(?u64, null), clock.deadline_ns);
}

test "moving the selection opens the new row while the old one closes" {
    var motion: SelectionMotion = .{};
    var clock: FrameClock = .{};
    clock.begin(0);
    _ = motion.sample(3, .{ .index = 0, .id = 9 }, &clock);

    clock.begin(std.time.ns_per_s);
    const started = motion.sample(3, .{ .index = 1, .id = 8 }, &clock);
    try std.testing.expectEqual(@as(f32, 0), started.open);
    try std.testing.expectEqual(@as(?HistoryPosition, .{ .index = 0, .id = 9 }), started.leaving);
    try std.testing.expectEqual(@as(f32, 1), started.leaving_open);
    try std.testing.expect(clock.deadline_ns != null);

    clock.begin(std.time.ns_per_s + duration_ns / 2);
    const halfway = motion.sample(3, .{ .index = 1, .id = 8 }, &clock);
    try std.testing.expectEqual(@as(f32, 0.875), halfway.open);
    try std.testing.expectEqual(@as(f32, 0.125), halfway.leaving_open);

    clock.begin(std.time.ns_per_s + duration_ns);
    const finished = motion.sample(3, .{ .index = 1, .id = 8 }, &clock);
    try std.testing.expectEqual(@as(f32, 1), finished.open);
    try std.testing.expectEqual(@as(?HistoryPosition, null), finished.leaving);
    try std.testing.expectEqual(@as(?u64, null), clock.deadline_ns);
}

test "a row left half open closes from where it was" {
    var motion: SelectionMotion = .{};
    var clock: FrameClock = .{};
    clock.begin(0);
    _ = motion.sample(3, .{ .index = 0, .id = 9 }, &clock);
    _ = motion.sample(3, .{ .index = 1, .id = 8 }, &clock);

    clock.begin(duration_ns / 2);
    const retargeted = motion.sample(3, .{ .index = 2, .id = 7 }, &clock);
    try std.testing.expectEqual(@as(f32, 0), retargeted.open);
    try std.testing.expectEqual(@as(?HistoryPosition, .{ .index = 1, .id = 8 }), retargeted.leaving);
    try std.testing.expectEqual(@as(f32, 0.875), retargeted.leaving_open);
}

test "a page replaced under the same position does not replay the motion" {
    var motion: SelectionMotion = .{};
    var clock: FrameClock = .{};
    clock.begin(0);
    _ = motion.sample(3, .{ .index = 0, .id = 9 }, &clock);

    clock.begin(std.time.ns_per_s);
    const replaced = motion.sample(3, .{ .index = 0, .id = 40 }, &clock);
    try std.testing.expectEqual(@as(f32, 1), replaced.open);
    try std.testing.expectEqual(@as(?HistoryPosition, null), replaced.leaving);
    try std.testing.expectEqual(@as(?u64, null), clock.deadline_ns);
}

test "closing, an empty page and a static composition leave no deadline" {
    var motion: SelectionMotion = .{};
    var clock: FrameClock = .{};
    clock.begin(0);
    _ = motion.sample(3, .{ .index = 0, .id = 9 }, &clock);
    _ = motion.sample(3, .{ .index = 4, .id = 5 }, &clock);

    clock.begin(1);
    try std.testing.expectEqual(@as(f32, 1), motion.sample(3, null, &clock).open);
    try std.testing.expectEqual(@as(?u64, null), clock.deadline_ns);
    try std.testing.expectEqual(@as(f32, 1), motion.sample(null, .{ .index = 0, .id = 9 }, &clock).open);
    try std.testing.expectEqual(@as(?u64, null), motion.generation);

    _ = motion.sample(3, .{ .index = 0, .id = 9 }, &clock);
    try std.testing.expectEqual(@as(f32, 1), motion.sample(3, .{ .index = 2, .id = 7 }, null).open);
    try std.testing.expectEqual(@as(f32, 1), motion.sample(3, .{ .index = 2, .id = 7 }, &clock).open);
    try std.testing.expectEqual(@as(?u64, null), clock.deadline_ns);
}
