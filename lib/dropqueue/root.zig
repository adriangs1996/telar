//! A bounded queue between many publishers and one receiver that never
//! makes a publisher wait: a full queue drops the item and counts the loss.

pub const GenericDropQueue = @import("GenericDropQueue.zig").Type;
pub const QueueMetrics = @import("QueueMetrics.zig");

test {
    _ = @import("GenericDropQueue.zig");
    _ = @import("QueueMetrics.zig");
    _ = @import("drop_queue_tests.zig");
}
