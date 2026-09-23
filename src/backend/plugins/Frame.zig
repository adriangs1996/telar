const core = @import("telar-core");
const std = @import("std");
const Frame = @This();

gpa: std.mem.Allocator,
event_id: u64,
pane: core.PaneId,
pane_generation: u64,
storage: []u8,
len: usize,

pub fn bytes(self: *const Frame) []u8 {
    return self.storage[0..self.len];
}

pub fn deinit(self: *Frame) void {
    const gpa = self.gpa;
    std.crypto.secureZero(u8, self.storage);
    gpa.free(self.storage);
    gpa.destroy(self);
}
