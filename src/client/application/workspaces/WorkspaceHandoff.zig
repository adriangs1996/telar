const WorkspaceHandoff = @This();
const source_namespace = @import("workspace_handoff.zig");
target: source_namespace.schema.PaneTarget,
fallback_workspace: ?source_namespace.schema.WorkspaceId,
size: source_namespace.schema.TerminalSize,
