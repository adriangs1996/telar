const std = @import("std");
const Sequence = @This();

value: std.atomic.Value(u64) = .init(0),

/// Reserves a unique SQLite-compatible sequence without wrapping on exhaustion.
/// Example: `const number = sequence.reserve() orelse return;`.
pub fn reserve(self: *Sequence) ?u64 {
    var previous = self.value.load(.monotonic);
    while (previous < std.math.maxInt(i64)) {
        if (self.value.cmpxchgWeak(previous, previous + 1, .monotonic, .monotonic)) |actual| {
            previous = actual;
        } else {
            return previous + 1;
        }
    }

    return null;
}
