//! Application command for forwarding input to one attached pane.

/// Attachment-validation outcome. `handled` includes a whole-message drop by
/// the bounded PTY queue because that backpressure policy is not a stale input.
pub const PaneInputResult = enum {
    handled,
    pane_not_attached,
    pane_exited,
};
