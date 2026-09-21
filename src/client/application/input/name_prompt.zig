//! Application boundary for the bounded client name prompt.

const NamePromptState = @import("../../model/NamePromptState.zig");
const std = @import("std");

pub const Outcome = enum {
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
