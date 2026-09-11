const std = @import("std");
const PaneType = @import("../../pane/Pane.zig");
const RuntimeMetricsType = @import("../observability/RuntimeMetrics.zig");
const Preparation = @This();

io: std.Io,
buffer: []u8,
pane: *PaneType,
force_snapshot: bool,
metrics: *RuntimeMetricsType,
