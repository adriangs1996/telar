const Attachments = @import("../attachment/Attachments.zig");

attachments: ?*const Attachments = null,
count: usize = 0,
response_queue_depth: usize = 0,
response_queue_high_water: usize = 0,
response_queue_dropped: u64 = 0,
