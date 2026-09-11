//! Owned domain events produced by workspace aggregate changes.
//!
//! Application handlers may hold an event while a wider runtime transaction
//! remains provisional and publish it only after that transaction commits.

const std = @import("std");
const core = @import("telar-core");

pub const schema = core.schema;

const OwnedTabLabel = @import("OwnedTabLabel.zig");

const OwnedWorkspaceName = @import("GenericOwnedWorkspaceName.zig").Type;

pub const OwnedExplicitWorkspaceName = OwnedWorkspaceName(schema.max_tab_label_bytes);
pub const OwnedCreatedWorkspaceName = OwnedWorkspaceName(schema.max_workspace_name_bytes);

pub const TabCreated = @import("TabCreated.zig");

pub const TabRemoved = @import("TabRemoved.zig");

pub const TabRenamed = @import("TabRenamed.zig");

pub const TabMoved = @import("TabMoved.zig");

pub const WorkspaceRenamed = @import("WorkspaceRenamed.zig");

pub const WorkspaceCreated = @import("WorkspaceCreated.zig");

fn testingLocation() !schema.TabLocation {
    return .{
        .workspace = .{ .workspace = try schema.id.workspace(3) },
        .tab_id = try schema.id.tab(7),
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

    const oversized: [schema.max_tab_label_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(error.InvalidTabLabel, TabCreated.init(location, 1, &oversized));
}

test "TabRemoved represents tab-only and whole-workspace removals" {
    const location = try testingLocation();
    const previous = try schema.id.workspace(2);
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
        TabRemoved.init(location, false, try schema.id.workspace(2)),
    );
    try std.testing.expectError(
        error.InvalidPreviousWorkspace,
        TabRemoved.init(location, true, removed_workspace),
    );

    const worktree_location: schema.TabLocation = .{
        .workspace = .{ .worktree = try schema.id.worktree(4) },
        .tab_id = location.tab_id,
    };
    try std.testing.expectError(
        error.InvalidPreviousWorkspace,
        TabRemoved.init(worktree_location, true, try schema.id.workspace(2)),
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

    const oversized: [schema.max_tab_label_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(error.InvalidTabLabel, TabRenamed.init(location, &oversized));
}

test "TabMoved identifies the committed tab and canonical position" {
    const location = try testingLocation();
    const event: TabMoved = .{ .location = location, .position = 2 };

    try std.testing.expectEqualDeep(location, event.location);
    try std.testing.expectEqual(@as(u16, 2), event.position);
}

test "WorkspaceRenamed owns its canonical name" {
    const location: schema.WorkspaceLocation = .{ .workspace = try schema.id.workspace(3) };
    var source = [_]u8{ 'b', 'a', 'c', 'k', 'e', 'n', 'd' };
    const event = try WorkspaceRenamed.init(location, &source);

    @memset(&source, 'x');

    try std.testing.expectEqualDeep(location, event.location);
    try std.testing.expectEqualStrings("backend", event.nameSlice());
}

test "WorkspaceRenamed rejects names the aggregate cannot store" {
    const location: schema.WorkspaceLocation = .{ .workspace = try schema.id.workspace(3) };

    try std.testing.expectError(error.InvalidWorkspaceName, WorkspaceRenamed.init(location, ""));

    const oversized: [schema.max_tab_label_bytes + 1]u8 = @splat('x');
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
    var source: [schema.max_tab_label_bytes + 1]u8 = @splat('p');
    const event = try WorkspaceCreated.init(location, &source);

    @memset(&source, 'x');

    try std.testing.expectEqual(@as(usize, schema.max_tab_label_bytes + 1), event.nameSlice().len);
    try std.testing.expect(std.mem.allEqual(u8, event.nameSlice(), 'p'));
}

test "WorkspaceCreated rejects names the aggregate cannot store" {
    const location = try testingLocation();

    try std.testing.expectError(error.InvalidWorkspaceName, WorkspaceCreated.init(location, ""));

    const oversized: [schema.max_workspace_name_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(error.InvalidWorkspaceName, WorkspaceCreated.init(location, &oversized));
}
