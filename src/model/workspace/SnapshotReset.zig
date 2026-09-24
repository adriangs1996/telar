const cellgrid = @import("cellgrid");
const Metrics = @import("Metrics.zig");
const SnapshotReset = @This();

area: cellgrid.Rect,
revision: u64,
pane_gaps: bool,
metrics: Metrics,
