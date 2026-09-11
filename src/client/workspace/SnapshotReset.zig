const SnapshotReset = @This();
const source_namespace = @import("layout_support.zig");
const Metrics = @import("metrics_support.zig").Metrics;
area: source_namespace.ui.Rect,
revision: u64,
pane_gaps: bool,
metrics: Metrics,
