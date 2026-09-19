const std = @import("std");
const Cursor = @import("Cursor.zig");
const ClientOptions = @This();

pub const Action = enum { list };
action: Action,
json: bool = false,
socket: ?[*:0]const u8 = null,

/// Parses interactive-client discovery. Example: `try ClientOptions.parse(&.{ "list", "--json" });`
pub fn parse(args: []const [*:0]const u8) !ClientOptions {
    if (args.len == 0) {
        return error.MissingClientAction;
    }

    var self: ClientOptions = .{ .action = std.meta.stringToEnum(Action, std.mem.span(args[0])) orelse return error.UnknownClientAction };
    var cursor: Cursor = .{ .remaining = args[1..] };
    while (cursor.next()) |argument| {
        const arg = std.mem.span(argument);
        if (std.mem.eql(u8, arg, "--json") and !self.json) {
            self.json = true;
        } else if (std.mem.eql(u8, arg, "--socket") and self.socket == null) {
            self.socket = try cursor.require(error.MissingSocketPath);
        } else {
            return error.UnknownClientOption;
        }
    }

    return self;
}
