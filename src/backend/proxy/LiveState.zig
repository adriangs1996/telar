const SlotSnapshot = @import("SlotSnapshot.zig");
const ObservationQueueMetrics = @import("ObservationQueueMetrics.zig");
const CaptureMetrics = @import("capture/CaptureMetrics.zig");
const LiveState = @This();

connections: SlotSnapshot,
observations: ObservationQueueMetrics,
captures: CaptureMetrics = .{},
