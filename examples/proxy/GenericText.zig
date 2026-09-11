/// An owned, bounded string. Nothing crossing the queue may borrow, because the
/// producer's buffer is gone by the time the main loop reads it.
pub fn Type(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        bytes: [capacity]u8 = undefined,
        len: usize = 0,

        pub fn set(self: *Self, text: []const u8) void {
            self.len = @min(text.len, capacity);
            @memcpy(self.bytes[0..self.len], text[0..self.len]);
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}
