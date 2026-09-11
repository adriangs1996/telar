const SlotSnapshotType = @import("SlotSnapshot.zig");
const ObservationQueueMetrics = @import("ObservationQueueMetrics.zig");
const CaptureMetrics = @import("capture/CaptureMetrics.zig");
const LiveState = @This();

connections: SlotSnapshotType,
observations: ObservationQueueMetrics,
captures: CaptureMetrics = .{},
