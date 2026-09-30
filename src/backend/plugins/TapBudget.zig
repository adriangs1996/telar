//! The bytes the tap holds: exchanges waiting in worker queues and the
//! frames workers are sending. Queues and workers charge it before they
//! hold bytes and release it when they let them go; what does not fit is
//! dropped and counted, so a slow plugin never grows the runtime past it.
const std = @import("std");
const TapBudget = @This();

max_bytes: usize,
held: std.atomic.Value(usize) = .init(0),
/// Exchanges and frames dropped because they did not fit.
dropped: std.atomic.Value(u64) = .init(0),

/// Charges `bytes` when they fit, or counts one drop.
///
/// ```zig
/// if (!budget.charge(size)) return;
/// defer budget.release(size);
/// ```
pub fn charge(self: *TapBudget, bytes: usize) bool {
    var current = self.held.load(.monotonic);
    while (bytes <= self.max_bytes -| current) {
        current = self.held.cmpxchgWeak(current, current + bytes, .monotonic, .monotonic) orelse return true;
    }

    _ = self.dropped.fetchAdd(1, .monotonic);
    return false;
}

/// Returns `bytes` a holder let go of.
///
/// ```zig
/// budget.release(size);
/// ```
pub fn release(self: *TapBudget, bytes: usize) void {
    const previous = self.held.fetchSub(bytes, .monotonic);
    std.debug.assert(previous >= bytes);
}

test "a charge past the budget is dropped and counted, and a release makes room" {
    var budget: TapBudget = .{
        .max_bytes = 8,
    };

    try std.testing.expect(budget.charge(7));
    try std.testing.expect(!budget.charge(2));
    try std.testing.expectEqual(@as(u64, 1), budget.dropped.load(.monotonic));

    budget.release(7);
    try std.testing.expect(budget.charge(8));
}
