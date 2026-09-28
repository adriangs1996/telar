//! A finished command's standard output, owned by its completion. The
//! consumer releases it with `deinit` whatever it decides to do with it.
const std = @import("std");
const Output = @This();

pub const allocator = std.heap.page_allocator;

/// The whole buffer the worker received, freed as one allocation.
buffer: []u8 = &.{},
start: usize = 0,
len: usize = 0,

pub fn slice(self: *const Output) []const u8 {
    return self.buffer[self.start..][0..self.len];
}

pub fn deinit(self: *Output) void {
    if (self.buffer.len != 0) {
        allocator.free(self.buffer);
    }

    self.* = .{};
}
