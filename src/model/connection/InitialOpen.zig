const core = @import("telar-core");
const InitialOpen = @This();

/// Retried when a remembered pane disappeared while its workspace was
/// inactive. Null for process bootstrap and non-workspace targets.
fallback_workspace: ?core.WorkspaceId = null,
