const Quota = @import("Quota.zig");
const std = @import("std");
const Reservation = @This();

quota: *Quota,
bytes: usize,

/// Grows the reservation by up to `bytes`, as much as its quota has left,
/// and returns how many bytes it gained.
///
/// ```zig
/// const gained = reservation.grow(needed - reservation.bytes);
/// ```
pub fn grow(self: *Reservation, bytes: usize) usize {
    const granted = self.quota.reserveAtMost(bytes);
    self.bytes += granted;
    return granted;
}

pub fn release(self: *Reservation) void {
    if (self.bytes == 0) {
        return;
    }

    const previous = self.quota.reserved.fetchSub(self.bytes, .monotonic);
    std.debug.assert(previous >= self.bytes);
    self.bytes = 0;
}
