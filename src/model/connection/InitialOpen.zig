const core = @import("telar-core");

/// Retried when a remembered pane disappeared while its workspace was
/// inactive. Null for process bootstrap and non-workspace targets.
fallback_workspace: ?core.WorkspaceId = null,
