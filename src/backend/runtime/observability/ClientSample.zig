const AttachmentStore = @import("../attachment/AttachmentStore.zig");
const ClientSample = @This();

attachment_stores: []const *const AttachmentStore = &.{},
count: usize = 0,
response_queue_depth: usize = 0,
response_queue_high_water: usize = 0,
response_queue_dropped: u64 = 0,
