const core = @import("telar-core");

/// What a runtime message that stopped at a limit needs to bring the
/// replica back, read from the message before its buffer is reused.
pub const RuntimeResync = union(enum) {
    /// The pane's graphics paused at the limit; a graphics snapshot
    /// resumes them.
    graphics: core.PaneId,
    /// The pane's cells may be partly applied; a pane snapshot replaces them.
    pane: core.PaneId,
    /// Anything else; a new session rebuilds the replica.
    session,
};
