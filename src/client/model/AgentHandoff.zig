const AgentHandoff = @This();
const source_namespace = @import("types.zig");
pane_id: source_namespace.schema.PaneId,
fallback_workspace: ?source_namespace.schema.WorkspaceId,
