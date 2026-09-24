//! A bounded inbox between worker tasks and one consumer: producers reserve
//! a slot before they start, so a completion never finds the queue full.

pub const DrainBudget = @import("DrainBudget.zig");
pub const GenericInbox = @import("GenericInbox.zig").Type;
pub const InboxSnapshot = @import("InboxSnapshot.zig");
pub const ProducerTicket = @import("ProducerTicket.zig");

test {
    _ = @import("DrainBudget.zig");
    _ = @import("GenericInbox.zig");
    _ = @import("InboxSnapshot.zig");
    _ = @import("ProducerTicket.zig");
    _ = @import("Wakeup.zig");
    _ = @import("inbox_tests.zig");
}
