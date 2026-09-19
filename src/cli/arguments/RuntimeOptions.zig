const std = @import("std");
const Cursor = @import("Cursor.zig");
const RuntimeOptions = @This();

json: bool = false,
socket: ?[*:0]const u8 = null,

/// Parses a read-only runtime query. Example: `try RuntimeOptions.parse(&.{"status", "--json"});`
pub fn parse(args: []const [*:0]const u8) !RuntimeOptions {
    if (args.len == 0 or !std.mem.eql(u8, std.mem.span(args[0]), "status")) {
        return error.UnknownRuntimeAction;
    }

    var self: RuntimeOptions = .{};
    var cursor: Cursor = .{ .remaining = args[1..] };
    while (cursor.next()) |argument| {
        const arg = std.mem.span(argument);
        if (std.mem.eql(u8, arg, "--json")) {
            if (self.json) {
                return error.DuplicateJsonOption;
            }

            self.json = true;
        } else if (std.mem.eql(u8, arg, "--socket")) {
            if (self.socket != null) {
                return error.DuplicateSocketOption;
            }

            self.socket = try cursor.require(error.MissingSocketPath);
        } else {
            return error.UnknownRuntimeOption;
        }
    }

    return self;
}

test "runtime status rejects ambiguous and incomplete options" {
    const options = try RuntimeOptions.parse(&.{ "status", "--socket", "/tmp/runtime.sock", "--json" });
    try std.testing.expect(options.json);
    try std.testing.expectEqualStrings("/tmp/runtime.sock", std.mem.span(options.socket.?));
    try std.testing.expectError(error.MissingSocketPath, RuntimeOptions.parse(&.{ "status", "--socket" }));
    try std.testing.expectError(error.DuplicateSocketOption, RuntimeOptions.parse(&.{ "status", "--socket", "a", "--socket", "b" }));
    try std.testing.expectError(error.UnknownRuntimeOption, RuntimeOptions.parse(&.{ "status", "--wat" }));
}
