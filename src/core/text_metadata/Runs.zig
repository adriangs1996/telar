const std = @import("std");
const LinkRun = @import("LinkRun.zig");
const size = @import("limits.zig").run_size;
const Runs = @This();

bytes: []const u8,
index: usize = 0,

/// Iterates previously validated row-local intervals. Example: `while (runs.next()) |run| { ... }`.
pub fn next(runs: *Runs) ?LinkRun {
    if (runs.index == runs.bytes.len) {
        return null;
    }

    const bytes = runs.bytes[runs.index..][0..size];
    runs.index += size;
    return .{ .start = std.mem.readInt(u32, bytes[0..4], .little), .len = std.mem.readInt(u32, bytes[4..8], .little), .link_index = std.mem.readInt(u16, bytes[8..10], .little) };
}
