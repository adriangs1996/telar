const std = @import("std");
const tab = @import("tab.zig");
const entity_target = @import("entity_target.zig");
const Cursor = @import("Cursor.zig");
const TabOptions = @This();
const core = @import("telar-core");

action: tab.Action,
workspace: entity_target.Target = .current,
socket: ?[*:0]const u8 = null,
json: bool = false,
target: ?entity_target.Target = null,
label: ?[*:0]const u8 = null,

/// Parses tab commands without runtime access. Example: `try TabOptions.parse(&.{"list", "--workspace", "1"});`
pub fn parse(args: []const [*:0]const u8) !TabOptions {
    if (args.len == 0) {
        return error.MissingTabAction;
    }

    const action = std.meta.stringToEnum(tab.Action, std.mem.span(args[0])) orelse return error.UnknownTabAction;
    var self: TabOptions = .{ .action = action };
    var workspace_seen = false;
    var index: usize = 1;
    if (action != .list) {
        if (args.len < 2) {
            return error.MissingTabTarget;
        }

        self.target = try entity_target.Target.parse(std.mem.span(args[1]));
        index = 2;
    }

    if (action == .rename) {
        if (args.len < 3) {
            return error.MissingTabLabel;
        }

        const label = std.mem.span(args[2]);
        if (label.len == 0 or label.len > core.max_tab_label_bytes or !std.unicode.utf8ValidateSlice(label)) {
            return error.InvalidTabLabel;
        }

        self.label = args[2];
        index = 3;
    }

    var cursor: Cursor = .{ .remaining = args[index..] };
    while (cursor.next()) |argument| {
        const arg = std.mem.span(argument);
        if (std.mem.eql(u8, arg, "--workspace")) {
            if (workspace_seen) {
                return error.DuplicateWorkspaceOption;
            }

            const value = try cursor.require(error.MissingWorkspaceTarget);
            self.workspace = try entity_target.Target.parse(std.mem.span(value));
            workspace_seen = true;
        } else if (std.mem.eql(u8, arg, "--socket")) {
            if (self.socket != null) {
                return error.DuplicateSocketOption;
            }

            self.socket = try cursor.require(error.MissingSocketPath);
        } else if (std.mem.eql(u8, arg, "--json")) {
            if (self.json) {
                return error.DuplicateJsonOption;
            }

            self.json = true;
        } else {
            return error.UnknownTabOption;
        }
    }

    return self;
}

test "tab list requires an unambiguous valid workspace option" {
    const options = try TabOptions.parse(&.{ "list", "--workspace", "42", "--json" });
    try std.testing.expectEqual(@as(u64, 42), options.workspace.id);
    try std.testing.expectError(error.InvalidIdentity, TabOptions.parse(&.{ "list", "--workspace", "0" }));
    try std.testing.expectError(error.DuplicateWorkspaceOption, TabOptions.parse(&.{ "list", "--workspace", "1", "--workspace", "2" }));
}
