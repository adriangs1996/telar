const Quota = @import("Quota.zig");
const std = @import("std");
const Reservation = @This();

quota: *Quota,
bytes: usize,

pub fn release(reservation: *Reservation) void {
    if (reservation.bytes == 0) {
        return;
    }

    const previous = reservation.quota.reserved.fetchSub(reservation.bytes, .monotonic);
    std.debug.assert(previous >= reservation.bytes);
    reservation.bytes = 0;
}
