//! Application command for resynchronizing one client's pane projection.

pub const RequestCellSnapshotResult = enum {
    requested,
    pane_not_attached,
};
