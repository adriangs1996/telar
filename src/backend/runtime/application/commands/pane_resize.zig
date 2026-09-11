//! Application command for resizing one attached pane.

pub const PaneResizeResult = enum {
    /// The request completed its applicable effects, including deferred
    /// application, pane closure, or disposal of a failed client projection.
    handled,
    pane_not_attached,
    geometry_rejected,
};
