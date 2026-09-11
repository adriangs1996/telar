const PaneStoreType = @import("../../../../pane/PaneStore.zig");
const RuntimeMetricsType = @import("../../../observability/RuntimeMetrics.zig");
const Resources = @This();

panes: *PaneStoreType,
metrics: *RuntimeMetricsType,
