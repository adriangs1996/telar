const core = @import("telar-core");

pub const WorkspaceSelectionTarget = union(enum) {
    position: usize,
    workspace: core.WorkspaceId,
};
