const WorkspaceHandoffFailure = @This();
const source_namespace = @import("workspace_handoff.zig");
fallback_workspace: ?source_namespace.schema.WorkspaceId,
code: source_namespace.schema.FailureCode,
