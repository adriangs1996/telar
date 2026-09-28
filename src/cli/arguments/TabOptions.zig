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
direction: ?core.TabMoveDirection = null,
relative_to: ?core.TabId = null,
/// `create`: open the tab without any UI switching to it.
background: bool = false,

/// Parses tab commands without runtime access. Example: `try TabOptions.parse(&.{"list", "--workspace", "1"});`
pub fn parse(args: []const [*:0]const u8) !TabOptions {
    if (args.len == 0) {
        return error.MissingTabAction;
    }

    const action = std.meta.stringToEnum(tab.Action, std.mem.span(args[0])) orelse return error.UnknownTabAction;
    var self: TabOptions = .{ .action = action };
    var workspace_seen = false;
    var index: usize = 1;
    if (action != .list and action != .create) {
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

    if (action == .move) {
        if (args.len < 3) {
            return error.MissingMoveDirection;
        }

        self.direction = std.meta.stringToEnum(core.TabMoveDirection, std.mem.span(args[2])) orelse return error.InvalidMoveDirection;
        index = 3;
    }

    var cursor: Cursor = .{ .remaining = args[index..] };
    while (cursor.next()) |argument| {
        const arg = std.mem.span(argument);
        if (std.mem.eql(u8, arg, "--relative-to") and action == .move) {
            if (self.relative_to != null) {
                return error.DuplicateRelativeTarget;
            }

            const value = try cursor.require(error.MissingRelativeTarget);
            const target = try entity_target.Target.parse(std.mem.span(value));
            if (target != .id) {
                return error.InvalidRelativeTarget;
            }

            self.relative_to = @enumFromInt(target.id);
        } else if (std.mem.eql(u8, arg, "--background") and action == .create) {
            if (self.background) {
                return error.DuplicateBackgroundOption;
            }

            self.background = true;
        } else if (std.mem.eql(u8, arg, "--label") and action == .create) {
            if (self.label != null) {
                return error.DuplicateLabelOption;
            }

            const value = try cursor.require(error.MissingTabLabel);
            const label = std.mem.span(value);
            if (label.len > core.max_tab_label_bytes or !std.unicode.utf8ValidateSlice(label)) {
                return error.InvalidTabLabel;
            }

            self.label = value;
        } else if (std.mem.eql(u8, arg, "--workspace")) {
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

    // Without --background, `tab create` goes to a UI and needs --client.
    if (action == .create and !self.background) {
        return error.MissingClientId;
    }

    return self;
}

test "a background tab takes a workspace and a label but no target" {
    const options = try TabOptions.parse(&.{ "create", "--background", "--label", "tests", "--workspace", "4", "--json" });
    try std.testing.expect(options.background);
    try std.testing.expectEqualStrings("tests", std.mem.span(options.label.?));
    try std.testing.expectEqual(@as(u64, 4), options.workspace.id);
    try std.testing.expectError(error.MissingClientId, TabOptions.parse(&.{"create"}));
    try std.testing.expectError(error.UnknownTabOption, TabOptions.parse(&.{ "get", "8", "--background" }));
}

test "tab move validates direction and its optional anchor" {
    const options = try TabOptions.parse(&.{ "move", "8", "previous", "--relative-to", "3" });
    try std.testing.expectEqual(core.TabMoveDirection.previous, options.direction.?);
    try std.testing.expectEqual(@as(u64, 3), core.raw(options.relative_to.?));
    try std.testing.expectError(error.InvalidMoveDirection, TabOptions.parse(&.{ "move", "8", "sideways" }));
    try std.testing.expectError(error.UnknownTabOption, TabOptions.parse(&.{ "get", "8", "--relative-to", "3" }));
}

test "tab list requires an unambiguous valid workspace option" {
    const options = try TabOptions.parse(&.{ "list", "--workspace", "42", "--json" });
    try std.testing.expectEqual(@as(u64, 42), options.workspace.id);
    try std.testing.expectError(error.InvalidIdentity, TabOptions.parse(&.{ "list", "--workspace", "0" }));
    try std.testing.expectError(error.DuplicateWorkspaceOption, TabOptions.parse(&.{ "list", "--workspace", "1", "--workspace", "2" }));
}
