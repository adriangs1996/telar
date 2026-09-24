const std = @import("std");
const SlotSnapshot = @import("SlotSnapshot.zig");
/// Owns the exact number of admitted connection workers and the number of
/// sockets rejected at the configured bound.
const Slots = @This();

limit: u32,
active: std.atomic.Value(u32) = .init(0),
limit_drops: std.atomic.Value(u64) = .init(0),

/// Creates an empty connection-slot counter with a fixed upper bound.
///
/// ```zig
/// var slots = Slots.init(64);
/// ```
pub fn init(limit: u32) Slots {
    return .{ .limit = limit };
}

/// Acquires one slot without allowing the observable count to exceed its
/// bound. Rejection records one limit drop.
///
/// ```zig
/// if (!slots.acquire()) {
///     closeRejectedConnection();
/// }
/// ```
pub fn acquire(self: *Slots) bool {
    var current = self.active.load(.monotonic);

    while (current < self.limit) {
        if (self.active.cmpxchgWeak(current, current + 1, .acq_rel, .monotonic)) |observed| {
            current = observed;
            continue;
        }

        return true;
    }

    _ = self.limit_drops.fetchAdd(1, .monotonic);
    return false;
}

/// Releases the slot owned by one completed or unscheduled connection.
///
/// ```zig
/// slots.release();
/// ```
pub fn release(self: *Slots) void {
    const previous = self.active.fetchSub(1, .acq_rel);
    std.debug.assert(previous != 0);
}

/// Returns a lock-free metrics snapshot.
///
/// ```zig
/// const metrics = slots.snapshot();
/// ```
pub fn snapshot(self: *const Slots) SlotSnapshot {
    return .{
        .active = self.active.load(.monotonic),
        .limit_drops = self.limit_drops.load(.monotonic),
    };
}

test "connection slots never expose a count above their bound" {
    var slots = Slots.init(2);

    try std.testing.expect(slots.acquire());
    try std.testing.expect(slots.acquire());
    try std.testing.expect(!slots.acquire());
    try std.testing.expectEqual(SlotSnapshot{ .active = 2, .limit_drops = 1 }, slots.snapshot());

    slots.release();
    try std.testing.expect(slots.acquire());
    try std.testing.expectEqual(SlotSnapshot{ .active = 2, .limit_drops = 1 }, slots.snapshot());

    slots.release();
    slots.release();
    try std.testing.expectEqual(SlotSnapshot{ .active = 0, .limit_drops = 1 }, slots.snapshot());
}

test "a zero connection limit rejects and counts every attempt" {
    var slots = Slots.init(0);

    try std.testing.expect(!slots.acquire());
    try std.testing.expect(!slots.acquire());
    try std.testing.expectEqual(SlotSnapshot{ .active = 0, .limit_drops = 2 }, slots.snapshot());
}
