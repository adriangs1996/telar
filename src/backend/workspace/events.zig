//! Owned domain events produced by workspace aggregate changes.
//!
//! Application handlers may hold an event while a wider runtime transaction
//! remains provisional and publish it only after that transaction commits.

const GenericOwnedWorkspaceName = @import("GenericOwnedWorkspaceName.zig").Type;
const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const max_workspace_name_bytes_module = @import("telar-core").max_workspace_name_bytes;
const TabLocationType = @import("telar-core").TabLocation;
const workspace_module = @import("telar-core").workspace;
const tab_module = @import("telar-core").tab;
const TabCreated = @import("TabCreated.zig");
const std = @import("std");
const TabRemoved = @import("TabRemoved.zig");
const worktree_module = @import("telar-core").worktree;
const TabRenamed = @import("TabRenamed.zig");
const TabMoved = @import("TabMoved.zig");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const WorkspaceRenamed = @import("WorkspaceRenamed.zig");
const WorkspaceCreated = @import("WorkspaceCreated.zig");

pub const OwnedExplicitWorkspaceName = GenericOwnedWorkspaceName(max_tab_label_bytes_module);
pub const OwnedCreatedWorkspaceName = GenericOwnedWorkspaceName(max_workspace_name_bytes_module);

fn testingLocation() !TabLocationType {
    return .{
        .workspace = .{ .workspace = try workspace_module(3) },
        .tab_id = try tab_module(7),
    };
}

test "TabCreated owns its canonical label and position" {
    const location = try testingLocation();
    var source = [_]u8{ 'l', 'o', 'g', 's' };
    const event = try TabCreated.init(location, 2, &source);

    @memset(&source, 'x');

    try std.testing.expectEqualDeep(location, event.location);
    try std.testing.expectEqual(@as(u16, 2), event.position);
    try std.testing.expectEqualStrings("logs", event.labelSlice());
}

test "TabCreated rejects labels it cannot own" {
    const location = try testingLocation();

    try std.testing.expectError(error.InvalidTabLabel, TabCreated.init(location, 1, ""));

    const oversized: [max_tab_label_bytes_module + 1]u8 = @splat('x');
    try std.testing.expectError(error.InvalidTabLabel, TabCreated.init(location, 1, &oversized));
}

test "TabRemoved represents tab-only and whole-workspace removals" {
    const location = try testingLocation();
    const previous = try workspace_module(2);
    const tab_only = try TabRemoved.init(location, false, null);
    const whole_workspace = try TabRemoved.init(location, true, previous);

    try std.testing.expectEqualDeep(location, tab_only.location);
    try std.testing.expect(!tab_only.workspace_removed);
    try std.testing.expect(tab_only.previous_workspace == null);
    try std.testing.expect(whole_workspace.workspace_removed);
    try std.testing.expectEqual(previous, whole_workspace.previous_workspace.?);
}

test "TabRemoved rejects impossible workspace handoffs" {
    const location = try testingLocation();
    const removed_workspace = switch (location.workspace) {
        .workspace => |workspace_id| workspace_id,
        .worktree => unreachable,
    };

    try std.testing.expectError(
        error.UnexpectedPreviousWorkspace,
        TabRemoved.init(location, false, try workspace_module(2)),
    );
    try std.testing.expectError(
        error.InvalidPreviousWorkspace,
        TabRemoved.init(location, true, removed_workspace),
    );

    const worktree_location: TabLocationType = .{
        .workspace = .{ .worktree = try worktree_module(4) },
        .tab_id = location.tab_id,
    };
    try std.testing.expectError(
        error.InvalidPreviousWorkspace,
        TabRemoved.init(worktree_location, true, try workspace_module(2)),
    );
}

test "TabRenamed owns its label independently of the source buffer" {
    const location = try testingLocation();
    var source = [_]u8{ 's', 'e', 'r', 'v', 'e', 'r' };
    const event = try TabRenamed.init(location, &source);

    @memset(&source, 'x');

    try std.testing.expectEqualDeep(location, event.location);
    try std.testing.expectEqualStrings("server", event.labelSlice());
}

test "TabRenamed rejects labels it cannot own" {
    const location = try testingLocation();

    try std.testing.expectError(error.InvalidTabLabel, TabRenamed.init(location, ""));

    const oversized: [max_tab_label_bytes_module + 1]u8 = @splat('x');
    try std.testing.expectError(error.InvalidTabLabel, TabRenamed.init(location, &oversized));
}

test "TabMoved identifies the committed tab and canonical position" {
    const location = try testingLocation();
    const event: TabMoved = .{ .location = location, .position = 2 };

    try std.testing.expectEqualDeep(location, event.location);
    try std.testing.expectEqual(@as(u16, 2), event.position);
}

test "WorkspaceRenamed owns its canonical name" {
    const location: WorkspaceLocationType = .{ .workspace = try workspace_module(3) };
    var source = [_]u8{ 'b', 'a', 'c', 'k', 'e', 'n', 'd' };
    const event = try WorkspaceRenamed.init(location, &source);

    @memset(&source, 'x');

    try std.testing.expectEqualDeep(location, event.location);
    try std.testing.expectEqualStrings("backend", event.nameSlice());
}

test "WorkspaceRenamed rejects names the aggregate cannot store" {
    const location: WorkspaceLocationType = .{ .workspace = try workspace_module(3) };

    try std.testing.expectError(error.InvalidWorkspaceName, WorkspaceRenamed.init(location, ""));

    const oversized: [max_tab_label_bytes_module + 1]u8 = @splat('x');
    try std.testing.expectError(error.InvalidWorkspaceName, WorkspaceRenamed.init(location, &oversized));
}

test "WorkspaceCreated owns its canonical name and root tab identity" {
    const location = try testingLocation();
    var source = [_]u8{ 'b', 'a', 'c', 'k', 'e', 'n', 'd' };
    const event = try WorkspaceCreated.init(location, &source);

    @memset(&source, 'x');

    try std.testing.expectEqualDeep(location, event.location);
    try std.testing.expectEqualStrings("backend", event.nameSlice());
}

test "WorkspaceCreated owns path-derived names beyond the explicit label limit" {
    const location = try testingLocation();
    var source: [max_tab_label_bytes_module + 1]u8 = @splat('p');
    const event = try WorkspaceCreated.init(location, &source);

    @memset(&source, 'x');

    try std.testing.expectEqual(@as(usize, max_tab_label_bytes_module + 1), event.nameSlice().len);
    try std.testing.expect(std.mem.allEqual(u8, event.nameSlice(), 'p'));
}

test "WorkspaceCreated rejects names the aggregate cannot store" {
    const location = try testingLocation();

    try std.testing.expectError(error.InvalidWorkspaceName, WorkspaceCreated.init(location, ""));

    const oversized: [max_workspace_name_bytes_module + 1]u8 = @splat('x');
    try std.testing.expectError(error.InvalidWorkspaceName, WorkspaceCreated.init(location, &oversized));
}
