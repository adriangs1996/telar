const Snapshot = @This();
const source_namespace = @import("graphics.zig");
pane_id: source_namespace.PaneId,
revision: u64,
phase: source_namespace.SnapshotPhase,
