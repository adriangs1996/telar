//! The last CPU percentages the runtime reported, oldest first, for the
//! built-in CPU sparkline. A fixed ring: a burst of samples overwrites the
//! oldest ones instead of growing.
const std = @import("std");
const CpuHistory = @This();

pub const capacity = 32;

samples: [capacity]u8 = @splat(0),
count: u8 = 0,
next: u8 = 0,

/// Example: `model.cpu_history.push(metrics.cpu_percent);`
pub fn push(self: *CpuHistory, percent: u8) void {
    self.samples[self.next] = percent;
    self.next = (self.next + 1) % capacity;
    self.count = @min(self.count + 1, capacity);
}

/// Copies the samples, oldest first, into `buffer`.
/// Example: `const ordered = model.cpu_history.ordered(&buffer);`
pub fn ordered(self: *const CpuHistory, buffer: *[capacity]u8) []const u8 {
    const start = (self.next + capacity - self.count) % capacity;
    for (0..self.count) |index| {
        buffer[index] = self.samples[(start + index) % capacity];
    }

    return buffer[0..self.count];
}

test "cpu history keeps the newest samples in order" {
    var history: CpuHistory = .{};
    for (0..capacity + 2) |value| {
        history.push(@intCast(value));
    }

    var buffer: [capacity]u8 = undefined;
    const values = history.ordered(&buffer);

    try std.testing.expectEqual(@as(usize, capacity), values.len);
    try std.testing.expectEqual(@as(u8, 2), values[0]);
    try std.testing.expectEqual(@as(u8, capacity + 1), values[capacity - 1]);
}
