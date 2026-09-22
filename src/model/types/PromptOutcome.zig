pub const PromptOutcome = enum {
    unchanged,
    routing_changed,
    changed,
    cancelled,
    /// The palette asked to delete its selected entry; the controller owns
    /// the wire effect.
    removed,
    /// The directory field asked for its selected completion; the
    /// controller owns the completion list.
    completion_requested,
    blocked,
    finished,
};
