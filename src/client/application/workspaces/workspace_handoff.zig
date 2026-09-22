//! Workspace selection by committed list position or stable runtime identity.

const WorkspaceIdType = @import("telar-core").WorkspaceId;

pub const SelectionTarget = union(enum) {
    position: usize,
    workspace: WorkspaceIdType,
};
