const EntryType = @import("Entry.zig");
const std = @import("std");
/// Process environment built from literal entries for tests that resolve
/// paths or capabilities from environment variables.
///
/// ```zig
/// var environment = try TestEnvironment.init(&.{.{ .name = "HOME", .value = "/home/adrian" }});
/// defer environment.deinit();
/// const environ: std.process.Environ = .{ .block = environment.block };
/// ```
const TestEnvironment = @This();

map: std.process.Environ.Map,
block: std.process.Environ.PosixBlock,

pub const Entry = @import("Entry.zig");

pub fn init(entries: []const EntryType) !TestEnvironment {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    errdefer map.deinit();

    for (entries) |entry| {
        try map.put(entry.name, entry.value);
    }

    return .{
        .block = try map.createPosixBlock(std.testing.allocator, .{}),
        .map = map,
    };
}

pub fn deinit(environment: *TestEnvironment) void {
    environment.block.deinit(std.testing.allocator);
    environment.map.deinit();
}
