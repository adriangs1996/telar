/// Owns the exact number of admitted connection workers and the number of
/// sockets rejected at the configured bound.
const Slots = @This();
const std = @import("std");
const SlotSnapshot = @import("SlotSnapshot.zig");
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
pub fn acquire(slots: *Slots) bool {
    var current = slots.active.load(.monotonic);

    while (current < slots.limit) {
        if (slots.active.cmpxchgWeak(current, current + 1, .acq_rel, .monotonic)) |observed| {
            current = observed;
            continue;
        }

        return true;
    }

    _ = slots.limit_drops.fetchAdd(1, .monotonic);
    return false;
}

/// Releases the slot owned by one completed or unscheduled connection.
///
/// ```zig
/// slots.release();
/// ```
pub fn release(slots: *Slots) void {
    const previous = slots.active.fetchSub(1, .acq_rel);
    std.debug.assert(previous != 0);
}

/// Returns a lock-free metrics snapshot.
///
/// ```zig
/// const metrics = slots.snapshot();
/// ```
pub fn snapshot(slots: *const Slots) SlotSnapshot {
    return .{
        .active = slots.active.load(.monotonic),
        .limit_drops = slots.limit_drops.load(.monotonic),
    };
}
