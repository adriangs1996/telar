const PaneStoreType = @import("../../../../pane/PaneStore.zig");
const TrackerType = @import("../../../../agent/Tracker.zig");
const RuntimeMetricsType = @import("../../../observability/RuntimeMetrics.zig");
const Resources = @This();

panes: *PaneStoreType,
agents: *TrackerType,
metrics: *RuntimeMetricsType,
