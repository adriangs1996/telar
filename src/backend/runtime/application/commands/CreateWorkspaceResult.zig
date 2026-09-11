const WorkspaceCreatedType = @import("../../../workspace/WorkspaceCreated.zig");
const PaneIdType = @import("telar-core").PaneId;
const CreateWorkspaceResult = @This();

created: WorkspaceCreatedType,
root_pane_id: PaneIdType,
