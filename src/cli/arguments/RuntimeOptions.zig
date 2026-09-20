const std = @import("std");
const Cursor = @import("Cursor.zig");
const runtime = @import("runtime.zig");
const RuntimeOptions = @This();

json: bool = false,
proxy_only: bool = false,
action: runtime.Action = .status,
count: ?u32 = null,
socket: ?[*:0]const u8 = null,

/// Parses a read-only runtime query. Example: `try RuntimeOptions.parse(&.{"status", "--json"});`
pub fn parse(args: []const [*:0]const u8) !RuntimeOptions {
    if (args.len == 0) {
        return error.UnknownRuntimeAction;
    }

    const action = std.meta.stringToEnum(runtime.Action, std.mem.span(args[0])) orelse return error.UnknownRuntimeAction;
    var self: RuntimeOptions = .{ .action = action };
    var cursor: Cursor = .{ .remaining = args[1..] };
    while (cursor.next()) |argument| {
        const arg = std.mem.span(argument);
        if (std.mem.eql(u8, arg, "--json") or (self.action == .watch and std.mem.eql(u8, arg, "--jsonl"))) {
            if (self.json) {
                return error.DuplicateJsonOption;
            }

            self.json = true;
        } else if (std.mem.eql(u8, arg, "--count") and self.action == .watch) {
            if (self.count != null) {
                return error.DuplicateCountOption;
            }

            const value = try cursor.require(error.MissingCount);
            self.count = std.fmt.parseUnsigned(u32, std.mem.span(value), 10) catch return error.InvalidCount;
            if (self.count == 0) {
                return error.InvalidCount;
            }
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

test "runtime watch bounds finite streams and rejects watch-only flags on status" {
    const options = try RuntimeOptions.parse(&.{ "watch", "--jsonl", "--count", "2" });
    try std.testing.expectEqual(runtime.Action.watch, options.action);
    try std.testing.expectEqual(@as(?u32, 2), options.count);
    try std.testing.expectError(error.InvalidCount, RuntimeOptions.parse(&.{ "watch", "--count", "0" }));
    try std.testing.expectError(error.UnknownRuntimeOption, RuntimeOptions.parse(&.{ "status", "--count", "1" }));
}

test "runtime status rejects ambiguous and incomplete options" {
    const options = try RuntimeOptions.parse(&.{ "status", "--socket", "/tmp/runtime.sock", "--json" });
    try std.testing.expect(options.json);
    try std.testing.expectEqualStrings("/tmp/runtime.sock", std.mem.span(options.socket.?));
    try std.testing.expectError(error.MissingSocketPath, RuntimeOptions.parse(&.{ "status", "--socket" }));
    try std.testing.expectError(error.DuplicateSocketOption, RuntimeOptions.parse(&.{ "status", "--socket", "a", "--socket", "b" }));
    try std.testing.expectError(error.UnknownRuntimeOption, RuntimeOptions.parse(&.{ "status", "--wat" }));
}
