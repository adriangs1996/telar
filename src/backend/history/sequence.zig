const Sequence = @This();
const std = @import("std");
value: std.atomic.Value(u64) = .init(0),

/// Reserves a unique SQLite-compatible sequence without wrapping on exhaustion.
/// Example: `const number = sequence.reserve() orelse return;`.
pub fn reserve(sequence: *Sequence) ?u64 {
    var previous = sequence.value.load(.monotonic);
    while (previous < std.math.maxInt(i64)) {
        if (sequence.value.cmpxchgWeak(previous, previous + 1, .monotonic, .monotonic)) |actual| {
            previous = actual;
        } else {
            return previous + 1;
        }
    }

    return null;
}
