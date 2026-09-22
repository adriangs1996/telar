const Submission = @import("../state/Submission.zig");

pub const PromptTransition = union(enum) {
    unchanged,
    routing_changed,
    changed,
    cancelled,
    /// The history palette asked to delete its selected entry.
    removed: u16,
    /// The directory field asked for its selected completion; the
    /// controller owns the list and answers with `replaceDirectory`.
    completion_requested,
    submitted: Submission,
};
