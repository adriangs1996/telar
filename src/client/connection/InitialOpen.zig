const InitialOpen = @This();
const source_namespace = @import("requests.zig");
/// Retried when a remembered pane disappeared while its workspace was
/// inactive. Null for process bootstrap and non-workspace targets.
fallback_workspace: ?source_namespace.schema.WorkspaceId = null,
