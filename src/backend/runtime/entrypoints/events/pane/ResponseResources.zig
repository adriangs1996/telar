const std = @import("std");
const PaneStoreType = @import("../../../../pane/PaneStore.zig");
const RuntimeMetricsType = @import("../../../observability/RuntimeMetrics.zig");
const Resources = @This();

io: std.Io,
panes: *PaneStoreType,
metrics: *RuntimeMetricsType,
