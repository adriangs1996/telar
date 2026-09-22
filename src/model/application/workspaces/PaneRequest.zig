const core = @import("telar-core");
const PaneRequest = @This();

pane_id: core.PaneId,
fallback_workspace: ?core.WorkspaceId,
