//! Application command for changing one client's pane viewport.

pub const SetPaneViewportResult = enum {
    changed,
    unchanged,
    pane_not_attached,
};
