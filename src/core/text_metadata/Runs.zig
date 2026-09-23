const limits = @import("limits.zig");
const std = @import("std");
const LinkRun = @import("LinkRun.zig");
const Runs = @This();

bytes: []const u8,
index: usize = 0,

/// Iterates previously validated row-local intervals. Example: `while (runs.next()) |run| { ... }`.
pub fn next(self: *Runs) ?LinkRun {
    if (self.index == self.bytes.len) {
        return null;
    }

    const bytes = self.bytes[self.index..][0..limits.run_size];
    self.index += limits.run_size;
    return .{ .start = std.mem.readInt(u32, bytes[0..4], .little), .len = std.mem.readInt(u32, bytes[4..8], .little), .link_index = std.mem.readInt(u16, bytes[8..10], .little) };
}
