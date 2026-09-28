//! The levels a fitted bar row shows its components at.
const FitInput = @import("FitInput.zig");
const FitLevel = @import("FitLevel.zig").FitLevel;
const model = @import("model.zig");
const BarFit = @This();

levels: [FitInput.max_slots][model.max_bar_nodes]FitLevel = @splat(@splat(.full)),
/// Top-level components moved to the overflow list.
hidden: u8 = 0,
/// The width the row needs at these levels, overflow chip included.
width: f32 = 0,

pub fn level(self: *const BarFit, slot: usize, node: usize) FitLevel {
    return self.levels[slot][node];
}

pub fn isVisible(self: *const BarFit, slot: usize, node: usize) bool {
    return self.levels[slot][node] != .hidden;
}
