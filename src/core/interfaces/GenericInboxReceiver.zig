pub fn Type(comptime Message: type) type {
    return struct {
        const Self = @This();

        pub const Error = error{ Canceled, Closed };

        pull_fn: *const fn (*anyopaque) Error!Message,
        context: *anyopaque,

        /// Waits for a message or cancellation. Closed queues drain before Closed.
        /// Only one consumer may pull; copying the handle does not enforce this.
        /// Example: const message = try receiver.pull();
        pub fn pull(self: *Self) Error!Message {
            return self.pull_fn(self.context);
        }
    };
}
