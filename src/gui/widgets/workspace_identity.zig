const client = @import("telar-client");
const core = @import("telar-core");
const data = @import("model");
const std = @import("std");

/// Bytes a generated context label can need.
pub const label_bytes = 64;

/// What navigation calls the context the tabs belong to: the workspace's
/// name, else a numbered placeholder naming its kind.
/// Example: `var storage: [workspace_identity.label_bytes]u8 = undefined; const text = workspace_identity.contextLabel(model, &storage);`
pub fn contextLabel(model: *const data.ClientModel, storage: *[label_bytes]u8) []const u8 {
    const name = model.workspaceName();
    if (name.len != 0) {
        return name;
    }

    const location = model.workspace orelse return "workspace";
    return switch (location) {
        .workspace => |id| std.fmt.bufPrint(storage, "workspace {d}", .{@intFromEnum(id)}) catch unreachable,
        .worktree => |id| std.fmt.bufPrint(storage, "worktree {d}", .{@intFromEnum(id)}) catch unreachable,
    };
}

/// The workspace the tabs model currently shows, if it is not a worktree.
/// Example: `const active = workspace_identity.activeId(projection);`
pub fn activeId(projection: *const client.Projection) ?core.WorkspaceId {
    const location = projection.model.workspace orelse return null;
    return switch (location) {
        .workspace => |id| id,
        .worktree => null,
    };
}

/// Retains only a still-listed project while handoff has no active tab model.
/// A confirmed worktree or unlisted workspace never inherits the old selection.
/// Example: `const id = workspace_identity.navigationId(projection, presented);`
pub fn navigationId(projection: *const client.Projection, presented: ?core.WorkspaceId) ?core.WorkspaceId {
    if (projection.model.workspace != null) {
        return activeId(projection);
    }

    const previous = presented orelse return null;
    return if (projection.workspaces.indexOf(previous) != null) previous else null;
}
