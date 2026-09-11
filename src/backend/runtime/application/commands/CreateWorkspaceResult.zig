const CreateWorkspaceResult = @This();
const workspace_mod = @import("../../../workspace/root.zig");
const source_namespace = @import("create_workspace.zig");
created: workspace_mod.WorkspaceCreated,
root_pane_id: source_namespace.schema.PaneId,
