const LiveState = @This();
const connection_admission = @import("connection_admission.zig");
const observation_queue = @import("observation_queue.zig");
const capture = @import("capture/root.zig");
connections: connection_admission.SlotSnapshot,
observations: observation_queue.Metrics,
captures: capture.Metrics = .{},
