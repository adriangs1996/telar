/// A first-in first-out queue of at most `capacity` values, stored inline so
/// pushing and popping never allocate.
///
/// ```zig
/// var jobs: GenericRing(Job, 16) = .{};
/// try jobs.push(job);
/// while (jobs.pop()) |next| try start(next);
/// ```
pub fn Type(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        pub const max_items = capacity;

        // SAFETY: push writes each ring slot before increasing count; pop reads only a queued slot.
        items: [capacity]T = undefined,
        head: usize = 0,
        count: usize = 0,

        /// Appends `value` behind every queued one.
        pub fn push(self: *Self, value: T) error{RingFull}!void {
            if (self.count == capacity) {
                return error.RingFull;
            }

            self.items[(self.head + self.count) % capacity] = value;
            self.count += 1;
        }

        /// Takes the oldest value.
        pub fn pop(self: *Self) ?T {
            if (self.count == 0) {
                return null;
            }

            const value = self.items[self.head];
            self.head = (self.head + 1) % capacity;
            self.count -= 1;

            return value;
        }
    };
}
