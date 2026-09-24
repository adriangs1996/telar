//! Application use case for reconciling the runtime workspace-list replica.

const WorkspaceListInput = @import("WorkspaceListInput.zig");
const EntryInput = @import("EntryInput.zig");
const workspace_list_rejection = @import("workspace_list_snapshot.zig");
const core = @import("telar-core");
const ClientModel = @import("../state/ClientModel.zig");
const WorkspaceListCommit = @import("../state/WorkspaceListCommit.zig");

pub const Rejection = enum {
    too_many_workspaces,
    workspace_path_too_long,
    workspace_list_too_large,
    duplicate_workspace,
};

pub const Outcome = union(enum) {
    stale,
    rejected: Rejection,
    applied: WorkspaceListCommit,
};

pub fn classifyRejection(err: anyerror) ?Rejection {
    return switch (err) {
        error.TooManyWorkspaces => .too_many_workspaces,
        error.WorkspacePathTooLong => .workspace_path_too_long,
        error.WorkspaceListTooLarge => .workspace_list_too_large,
        error.DuplicateWorkspace => .duplicate_workspace,
        else => null,
    };
}

/// Decodes a bounded runtime list and preserves the previous replica on rejection.
/// Example: `_ = try self.applyWorkspaceList(list);`
pub fn apply(model: *ClientModel, list: core.WorkspaceListView) !workspace_list_rejection.Outcome {
    var entries: [core.max_workspace_list_entries]EntryInput = undefined;
    var count: usize = 0;
    var iterator = list.entries();
    while (try iterator.next()) |entry| {
        entries[count] = .{
            .workspace = entry.workspace,
            .name = entry.name,
            .path = entry.path,
            .tab_count = entry.tab_count,
            .branch = entry.branch,
            .dirty = entry.dirty,
        };
        count += 1;
    }

    const commit = reconcile(model, 
        .{
            .revision = list.revision,
            .entries = entries[0..count],
        },
    ) catch |err| {
        const rejection = workspace_list_rejection.classifyRejection(err) orelse return err;
        return .{
            .rejected = rejection,
        };
    };

    return if (commit) |value| .{
        .applied = value,
    } else .stale;
}

/// Commits one newer runtime workspace-list replica atomically. Stale
/// revisions preserve both the stored snapshot and its model version.
///
/// ```zig
/// const commit = try workspace_list_snapshot.reconcile(model, input) orelse return;
/// ```
pub fn reconcile(model: *ClientModel, input: WorkspaceListInput) !?WorkspaceListCommit {
    if (!try model.workspace_list_snapshot.replace(input)) {
        return null;
    }

    model.workspace_list_revision +%= 1;

    return .{
        .runtime_revision = model.workspace_list_snapshot.revision,
        .count = model.workspace_list_snapshot.count,
        .workspace_list_revision = model.workspace_list_revision,
    };
}

/// Reports whether the latest runtime list contains one workspace.
///
/// ```zig
/// if (!workspace_list_snapshot.knowsWorkspace(model, workspace)) return;
/// ```
pub fn knowsWorkspace(model: *const ClientModel, workspace: core.WorkspaceId) bool {
    return model.workspace_list_snapshot.indexOf(workspace) != null;
}
