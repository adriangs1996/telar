//! A process environment block built from test entries.
const std = @import("std");
const TestEnvironment = @This();

map: std.process.Environ.Map,
block: std.process.Environ.PosixBlock,

pub fn init(entries: []const [2][]const u8) !TestEnvironment {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    errdefer map.deinit();
    for (entries) |entry| {
        try map.put(entry[0], entry[1]);
    }
    const block = try map.createPosixBlock(std.testing.allocator, .{});
    return .{ .map = map, .block = block };
}

pub fn deinit(self: *TestEnvironment) void {
    self.block.deinit(std.testing.allocator);
    self.map.deinit();
}

pub fn environ(self: *const TestEnvironment) std.process.Environ {
    return .{ .block = self.block };
}
