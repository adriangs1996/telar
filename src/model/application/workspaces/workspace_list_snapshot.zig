//! Application use case for reconciling the runtime workspace-list replica.

const WorkspaceListCommitType = @import("../../state/WorkspaceListCommit.zig");

pub const Rejection = enum {
    too_many_workspaces,
    workspace_path_too_long,
    workspace_list_too_large,
    duplicate_workspace,
};

pub const Outcome = union(enum) {
    stale,
    rejected: Rejection,
    applied: WorkspaceListCommitType,
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
