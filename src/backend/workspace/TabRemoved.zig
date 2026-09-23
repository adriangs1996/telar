const core = @import("telar-core");
/// Committed disappearance of a tab from its workspace aggregate.
const TabRemoved = @This();

location: core.TabLocation,
workspace_removed: bool,
previous_workspace: ?core.WorkspaceId = null,

/// Creates a removal fact and rejects an impossible workspace handoff.
/// A predecessor exists only when the removal also removed its workspace.
///
/// ```zig
/// const event = try TabRemoved.init(location, true, previous_workspace);
/// ```
pub fn init(location: core.TabLocation, workspace_removed: bool, previous_workspace: ?core.WorkspaceId) !TabRemoved {
    if (!workspace_removed and previous_workspace != null) {
        return error.UnexpectedPreviousWorkspace;
    }

    if (previous_workspace) |previous| {
        const removed_workspace = switch (location.workspace) {
            .workspace => |workspace_id| workspace_id,
            .worktree => return error.InvalidPreviousWorkspace,
        };

        if (previous == removed_workspace) {
            return error.InvalidPreviousWorkspace;
        }
    }

    return .{
        .location = location,
        .workspace_removed = workspace_removed,
        .previous_workspace = previous_workspace,
    };
}

const std = @import("std");

fn testingLocation() !core.TabLocation {
    return .{ .workspace = .{ .workspace = try core.workspace(3) }, .tab_id = try core.tab(7) };
}

test "TabRemoved represents tab-only and whole-workspace removals" {
    const location = try testingLocation();
    const previous = try core.workspace(2);
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
    const removed_workspace = location.workspace.workspace;

    try std.testing.expectError(error.UnexpectedPreviousWorkspace, TabRemoved.init(location, false, try core.workspace(2)));
    try std.testing.expectError(error.InvalidPreviousWorkspace, TabRemoved.init(location, true, removed_workspace));

    const worktree_location: core.TabLocation = .{ .workspace = .{ .worktree = try core.worktree(4) }, .tab_id = location.tab_id };
    try std.testing.expectError(error.InvalidPreviousWorkspace, TabRemoved.init(worktree_location, true, try core.workspace(2)));
}
