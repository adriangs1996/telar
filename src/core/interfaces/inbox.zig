//! Inbox interface for use as sink for messages.
//! Implementations of this interface must follow
//! the one consumer, many producers pattern. Use
//! it as dependency in internal queues for async
//! work

pub fn Inbox(comptime Message: type) type {
    return struct {
        pub const Result = enum {
            accepted,
            full,
            closed,
        };

        const Self = @This();

        post_fn: *const fn (*anyopaque, Message) Result,
        context: *anyopaque,

        /// Attempts admission without waiting for capacity; full and closed reject it.
        /// The handle borrows its context. Payload ownership follows the implementation.
        /// Example: switch (sink.post(message)) { .accepted => {}, .full, .closed => return }
        pub fn post(self: *Self, msg: Message) Result {
            return self.post_fn(self.context, msg);
        }
    };
}
