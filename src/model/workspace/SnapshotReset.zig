const cellgrid = @import("cellgrid");
const Metrics = @import("Metrics.zig");

area: cellgrid.Rect,
revision: u64,
pane_gaps: bool,
metrics: Metrics,
