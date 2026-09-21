//! Application policy for resolving one workspace-handoff destination.

const WorkspaceIdType = @import("telar-core").WorkspaceId;
const PaneRequest = @import("PaneRequest.zig");

pub const Target = union(enum) {
    workspace: WorkspaceIdType,
    pane: PaneRequest,
};
