const Plan = @This();
const source_namespace = @import("workspace_handoff_targeting.zig");
target: source_namespace.schema.PaneTarget,
fallback_workspace: ?source_namespace.schema.WorkspaceId,
