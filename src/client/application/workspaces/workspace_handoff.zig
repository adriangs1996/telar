//! Application use cases for leaving, entering and recovering a workspace handoff.

const WorkspaceIdType = @import("telar-core").WorkspaceId;

pub const SelectionTarget = union(enum) {
    position: usize,
    workspace: WorkspaceIdType,
};

pub const WorkspaceRecovery = enum {
    retried,
    unrecoverable,
};
