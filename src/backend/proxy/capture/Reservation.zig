const Reservation = @This();
const Quota = @import("Quota.zig");
const std = @import("std");
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
