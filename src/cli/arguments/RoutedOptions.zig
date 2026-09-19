const std = @import("std");
const core = @import("telar-core");
const Cursor = @import("Cursor.zig");
const RoutedOptions = @This();

action: core.ClientAction,
client_id: u64 = 0,
target_id: u64 = 0,
value: i64 = 0,
text: []const u8 = "",
json: bool = false,
socket: ?[*:0]const u8 = null,

/// Recognizes actions owned by a specific UI. Example: `if (try RoutedOptions.parse(args)) |options| { ... }`
pub fn parse(args: []const [*:0]const u8) !?RoutedOptions {
    if (args.len < 2) {
        return null;
    }

    const group = std.mem.span(args[0]);
    const verb = std.mem.span(args[1]);
    var name_buffer: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buffer, "{s}_{s}", .{ group, verb }) catch return null;
    const action = std.meta.stringToEnum(core.ClientAction, name) orelse return null;
    var self: RoutedOptions = .{ .action = action };
    var cursor: Cursor = .{ .remaining = args[2..] };
    switch (action) {
        .pane_create => {},
        .tab_previous => {},
        .tab_next => {},
        .tab_select => self.target_id = try positive(std.mem.span(try cursor.require(error.MissingTarget))),
        .workspace_select => self.target_id = try positive(std.mem.span(try cursor.require(error.MissingTarget))),
        .tab_create => {},
    }
    while (cursor.next()) |argument| {
        const arg = std.mem.span(argument);
        if (std.mem.eql(u8, arg, "--client") and self.client_id == 0) {
            self.client_id = try positive(std.mem.span(try cursor.require(error.MissingClientId)));
        } else if (std.mem.eql(u8, arg, "--label") and self.action == .tab_create and self.text.len == 0) {
            self.text = std.mem.span(try cursor.require(error.MissingLabel));
        } else if (std.mem.eql(u8, arg, "--json") and !self.json) {
            self.json = true;
        } else if (std.mem.eql(u8, arg, "--socket") and self.socket == null) {
            self.socket = try cursor.require(error.MissingSocketPath);
        } else {
            return error.UnknownClientCommandOption;
        }
    }

    if (self.client_id == 0) {
        return error.MissingClientId;
    }

    return self;
}

fn positive(value: []const u8) !u64 {
    const parsed = std.fmt.parseUnsigned(u64, value, 10) catch return error.InvalidTarget;
    if (parsed == 0) {
        return error.InvalidTarget;
    }

    return parsed;
}

test "routed commands require an explicit positive UI client and target" {
    try std.testing.expectError(error.MissingClientId, parse(&.{ "workspace", "select", "42" }));
    try std.testing.expectError(error.InvalidTarget, parse(&.{ "workspace", "select", "0", "--client", "7" }));
    const options = (try parse(&.{ "workspace", "select", "42", "--client", "7", "--json" })).?;
    try std.testing.expectEqual(@as(u64, 42), options.target_id);
    try std.testing.expectEqual(@as(u64, 7), options.client_id);
}
