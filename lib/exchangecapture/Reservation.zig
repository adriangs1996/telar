const Quota = @import("Quota.zig");
const std = @import("std");
const Reservation = @This();

quota: *Quota,
bytes: usize,

pub fn release(self: *Reservation) void {
    if (self.bytes == 0) {
        return;
    }

    const previous = self.quota.reserved.fetchSub(self.bytes, .monotonic);
    std.debug.assert(previous >= self.bytes);
    self.bytes = 0;
}
