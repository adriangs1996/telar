const PaneRequest = @This();
const source_namespace = @import("workspace_handoff_targeting.zig");
pane_id: source_namespace.schema.PaneId,
fallback_workspace: ?source_namespace.schema.WorkspaceId,
