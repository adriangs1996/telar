const std = @import("std");
/// Bytes borrowed by the write worker until the owning state receives completion.
const WriteJob = @This();

io: std.Io,
path: []const u8,
buffer: []u8,
len: usize,

pub fn bytes(self: *const WriteJob) []const u8 {
    return self.buffer[0..self.len];
}
