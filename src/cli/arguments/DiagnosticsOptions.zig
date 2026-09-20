const std = @import("std");
const Cursor = @import("Cursor.zig");
const Options = @This();
pub const Component = enum { all, runtime, client };
component: Component = .all,
pid: ?u32 = null,
lines: u16 = 100,
json: bool = false,
socket: ?[*:0]const u8 = null,

/// Parses bounded local telemetry reads. Example: `const options = try DiagnosticsOptions.parse(args);`
pub fn parse(args: []const [*:0]const u8) !Options {
    if (args.len == 0 or !std.mem.eql(u8, std.mem.span(args[0]), "logs")) {
        return error.UnknownDiagnosticsAction;
    }

    var self: Options = .{};
    var cursor: Cursor = .{ .remaining = args[1..] };
    while (cursor.next()) |argument| {
        const arg = std.mem.span(argument);
        if (std.mem.eql(u8, arg, "--component")) {
            self.component = std.meta.stringToEnum(Component, std.mem.span(try cursor.require(error.MissingComponent))) orelse return error.InvalidComponent;
        } else if (std.mem.eql(u8, arg, "--pid") and self.pid == null) {
            self.pid = std.fmt.parseUnsigned(u32, std.mem.span(try cursor.require(error.MissingPid)), 10) catch return error.InvalidPid;
            if (self.pid == 0) {
                return error.InvalidPid;
            }
        } else if (std.mem.eql(u8, arg, "--lines")) {
            self.lines = std.fmt.parseUnsigned(u16, std.mem.span(try cursor.require(error.MissingLineCount)), 10) catch return error.InvalidLineCount;
            if (self.lines == 0 or self.lines > 10000) {
                return error.InvalidLineCount;
            }
        } else if (std.mem.eql(u8, arg, "--json") and !self.json) {
            self.json = true;
        } else if (std.mem.eql(u8, arg, "--socket") and self.socket == null) {
            self.socket = try cursor.require(error.MissingSocketPath);
        } else {
            return error.UnknownDiagnosticsOption;
        }
    }

    return self;
}

test "diagnostic reads reject unbounded line counts and invalid process IDs" {
    try std.testing.expectError(error.InvalidLineCount, parse(&.{ "logs", "--lines", "0" }));
    try std.testing.expectError(error.InvalidPid, parse(&.{ "logs", "--pid", "0" }));
    try std.testing.expectError(error.InvalidComponent, parse(&.{ "logs", "--component", "worker" }));
}
