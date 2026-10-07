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
