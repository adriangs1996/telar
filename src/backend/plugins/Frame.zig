const core = @import("telar-core");
const std = @import("std");
const Frame = @This();

gpa: std.mem.Allocator,
event_id: u64,
pane: core.PaneId,
pane_generation: u64,
storage: []u8,
len: usize,

pub fn bytes(frame: *const Frame) []u8 {
    return frame.storage[0..frame.len];
}

pub fn deinit(frame: *Frame) void {
    const gpa = frame.gpa;
    std.crypto.secureZero(u8, frame.storage);
    gpa.free(frame.storage);
    gpa.destroy(frame);
}
