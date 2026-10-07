const Config = @import("Config.zig");
const std = @import("std");

pub const ParseResult = union(enum) {
    config: Config,
    unknown_option: []const u8,
};

/// Parses `codestyle [--fix] [PATH...]` without retaining argument storage.
///
/// ```zig
/// const result = try parse(allocator, &.{ "codestyle", "--fix", "src" });
/// ```
pub fn parse(allocator: std.mem.Allocator, arguments: []const [:0]const u8) !ParseResult {
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);

    var fix = false;

    for (arguments[1..]) |argument| {
        if (std.mem.eql(u8, argument, "--fix")) {
            fix = true;
            continue;
        }

        if (std.mem.startsWith(u8, argument, "-")) {
            return .{ .unknown_option = argument };
        }

        try paths.append(allocator, argument);
    }

    if (paths.items.len == 0) {
        try paths.append(allocator, ".");
    }

    return .{ .config = .{
        .fix = fix,
        .paths = try paths.toOwnedSlice(allocator),
    } };
}
