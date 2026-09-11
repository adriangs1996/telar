const TabLocationType = @import("telar-core").TabLocation;
const WorkspaceIdType = @import("telar-core").WorkspaceId;
/// Committed disappearance of a tab from its workspace aggregate.
const TabRemoved = @This();

location: TabLocationType,
workspace_removed: bool,
previous_workspace: ?WorkspaceIdType = null,

/// Creates a removal fact and rejects an impossible workspace handoff.
/// A predecessor exists only when the removal also removed its workspace.
///
/// ```zig
/// const event = try TabRemoved.init(location, true, previous_workspace);
/// ```
pub fn init(location: TabLocationType, workspace_removed: bool, previous_workspace: ?WorkspaceIdType) !TabRemoved {
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
