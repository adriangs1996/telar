//! Per-client synchronization state for one pane's Kitty graphics projection.

pub const SnapshotState = enum { begin_pending, open, idle };
