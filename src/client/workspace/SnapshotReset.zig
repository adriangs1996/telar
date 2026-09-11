const RectType = @import("telar-core").Rect;
const Metrics = @import("Metrics.zig");
const SnapshotReset = @This();

area: RectType,
revision: u64,
pane_gaps: bool,
metrics: Metrics,
