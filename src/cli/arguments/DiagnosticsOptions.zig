const std = @import("std");
const Cursor = @import("Cursor.zig");
const Options = @This();
pub const Component = enum { all, runtime, client };
/// `logs` reads the log files beside the socket; `limits` asks the runtime
/// for the limits it and its windows reached.
pub const Action = enum { logs, limits };
action: Action = .logs,
component: Component = .all,
pid: ?u32 = null,
lines: u16 = 100,
json: bool = false,
socket: ?[*:0]const u8 = null,

/// Parses bounded local telemetry reads. Example: `const options = try DiagnosticsOptions.parse(args);`
pub fn parse(args: []const [*:0]const u8) !Options {
    if (args.len == 0) {
        return error.UnknownDiagnosticsAction;
    }

    var self: Options = .{
        .action = std.meta.stringToEnum(Action, std.mem.span(args[0])) orelse return error.UnknownDiagnosticsAction,
    };
    var cursor: Cursor = .{ .remaining = args[1..] };
    while (cursor.next()) |argument| {
        const arg = std.mem.span(argument);
        const reads_logs = self.action == .logs;
        if (std.mem.eql(u8, arg, "--component") and reads_logs) {
            self.component = std.meta.stringToEnum(Component, std.mem.span(try cursor.require(error.MissingComponent))) orelse return error.InvalidComponent;
        } else if (std.mem.eql(u8, arg, "--pid") and self.pid == null and reads_logs) {
            self.pid = std.fmt.parseUnsigned(u32, std.mem.span(try cursor.require(error.MissingPid)), 10) catch return error.InvalidPid;
            if (self.pid == 0) {
                return error.InvalidPid;
            }
        } else if (std.mem.eql(u8, arg, "--lines") and reads_logs) {
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

test "limits takes only the socket and json options" {
    const options = try parse(&.{ "limits", "--json" });
    try std.testing.expectEqual(Action.limits, options.action);
    try std.testing.expect(options.json);
    try std.testing.expectError(error.UnknownDiagnosticsOption, parse(&.{ "limits", "--lines", "5" }));
    try std.testing.expectError(error.UnknownDiagnosticsAction, parse(&.{"counters"}));
}
