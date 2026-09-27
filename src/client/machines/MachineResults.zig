//! The window's machines the palette's `:` mode matched, best first.
const Machines = @import("Machines.zig");
const MachineResults = @This();

slots: [Machines.capacity]u8 = undefined,
scores: [Machines.capacity]u32 = undefined,
len: u8 = 0,

pub fn slice(self: *const MachineResults) []const u8 {
    return self.slots[0..self.len];
}
