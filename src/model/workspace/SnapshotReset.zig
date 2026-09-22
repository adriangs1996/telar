const core = @import("telar-core");
const Metrics = @import("Metrics.zig");
const SnapshotReset = @This();

area: core.Rect,
revision: u64,
pane_gaps: bool,
metrics: Metrics,
