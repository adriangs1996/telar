//! Application command for rebuilding one client's graphics projection.

pub const RequestGraphicsSnapshotResult = enum {
    requested,
    pane_not_attached,
};
