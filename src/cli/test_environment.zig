const std = @import("std");

/// Process environment built from literal entries for tests that resolve
/// paths or capabilities from environment variables.
///
/// ```zig
/// var environment = try TestEnvironment.init(&.{.{ "HOME", "/home/adrian" }});
/// defer environment.deinit();
/// const environ: std.process.Environ = .{ .block = environment.block };
/// ```
pub const TestEnvironment = struct {
    map: std.process.Environ.Map,
    block: std.process.Environ.PosixBlock,

    pub const Entry = struct { []const u8, []const u8 };

    pub fn init(entries: []const Entry) !TestEnvironment {
        var map = std.process.Environ.Map.init(std.testing.allocator);
        errdefer map.deinit();

        for (entries) |entry| {
            try map.put(entry[0], entry[1]);
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
};
