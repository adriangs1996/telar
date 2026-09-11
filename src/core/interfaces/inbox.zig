//! Inbox interface for use as sink for messages.
//! Implementations of this interface must follow
//! the one consumer, many producers pattern. Use
//! it as dependency in internal queues for async
//! work

pub const Inbox = @import("GenericInbox.zig").Type;
