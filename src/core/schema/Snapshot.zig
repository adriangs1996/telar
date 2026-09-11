const id = @import("id.zig");
const graphics = @import("graphics.zig");
const Snapshot = @This();

pane_id: id.PaneId,
revision: u64,
phase: graphics.SnapshotPhase,
