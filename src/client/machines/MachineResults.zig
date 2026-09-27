//! The window's machines the palette's `:` mode matched, best first, and
//! the "Add machine" row after them.
const Machines = @import("Machines.zig");
const MachineResults = @This();

slots: [Machines.capacity]u8 = undefined,
scores: [Machines.capacity]u32 = undefined,
len: u8 = 0,

pub fn slice(self: *const MachineResults) []const u8 {
    return self.slots[0..self.len];
}

/// Rows the list shows: the matches and the "Add machine" row.
pub fn rows(self: *const MachineResults) u16 {
    return @as(u16, self.len) + 1;
}

/// The machine a row names, or null for the "Add machine" row.
pub fn slotAt(self: *const MachineResults, row: u16) ?u8 {
    return if (row < self.len) self.slots[row] else null;
}
