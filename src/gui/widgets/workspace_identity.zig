const client = @import("telar-client");
const core = @import("telar-core");

/// The workspace the tabs model currently shows, if it is not a worktree.
/// Example: `const active = workspace_identity.activeId(projection);`
pub fn activeId(projection: *const client.Projection) ?core.WorkspaceId {
    const location = projection.tabs.workspace orelse return null;
    return switch (location) {
        .workspace => |id| id,
        .worktree => null,
    };
}

/// Retains only a still-listed project while handoff has no active tab model.
/// A confirmed worktree or unlisted workspace never inherits the old selection.
/// Example: `const id = workspace_identity.navigationId(projection, presented);`
pub fn navigationId(projection: *const client.Projection, presented: ?core.WorkspaceId) ?core.WorkspaceId {
    if (projection.tabs.workspace != null) {
        return activeId(projection);
    }

    const previous = presented orelse return null;
    return if (projection.workspaces.indexOf(previous) != null) previous else null;
}
