const WorkspaceIdType = @import("telar-core").WorkspaceId;
const InitialOpen = @This();

/// Retried when a remembered pane disappeared while its workspace was
/// inactive. Null for process bootstrap and non-workspace targets.
fallback_workspace: ?WorkspaceIdType = null,
