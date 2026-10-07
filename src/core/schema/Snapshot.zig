const id = @import("id.zig");
const graphics = @import("graphics.zig");

pane_id: id.PaneId,
revision: u64,
phase: graphics.SnapshotPhase,
