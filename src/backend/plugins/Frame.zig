const std = @import("std");
const Frame = @This();

gpa: std.mem.Allocator,
event_id: u64,
storage: []u8,
len: usize,
/// The queued-bytes budget this frame's storage is charged to, released
/// when the frame is freed; null for a frame outside the budget.
budget: ?*std.atomic.Value(usize) = null,

pub fn bytes(self: *const Frame) []u8 {
    return self.storage[0..self.len];
}

pub fn deinit(self: *Frame) void {
    const gpa = self.gpa;
    if (self.budget) |budget| {
        _ = budget.fetchSub(self.storage.len, .monotonic);
    }

    std.crypto.secureZero(u8, self.storage);
    gpa.free(self.storage);
    gpa.destroy(self);
}
