const core = @import("telar-core");
const WorkspaceCreatedType = @import("../../../workspace/WorkspaceCreated.zig");
const CreateWorkspaceResult = @This();

created: WorkspaceCreatedType,
root_pane_id: core.PaneId,
