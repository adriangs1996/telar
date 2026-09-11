const PaneIdType = @import("telar-core").PaneId;
const WorkspaceIdType = @import("telar-core").WorkspaceId;
const AgentHandoff = @This();

pane_id: PaneIdType,
fallback_workspace: ?WorkspaceIdType,
