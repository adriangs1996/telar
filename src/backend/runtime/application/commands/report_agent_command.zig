//! Application command for shell-tool reports emitted by official agent hooks.

pub const Outcome = enum { applied, pane_not_found, queue_full };
