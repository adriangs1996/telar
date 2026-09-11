const ClientSample = @This();
const source_namespace = @import("telemetry.zig");
attachment_stores: []const *const source_namespace.AttachmentStore = &.{},
count: usize = 0,
response_queue_depth: usize = 0,
response_queue_high_water: usize = 0,
response_queue_dropped: u64 = 0,
