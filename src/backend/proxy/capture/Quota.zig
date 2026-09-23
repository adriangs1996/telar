const std = @import("std");
const Reservation = @import("Reservation.zig");
const Quota = @This();

max_bytes: usize,
reserved: std.atomic.Value(usize) = .init(0),

pub fn init(max_bytes: usize) Quota {
    return .{ .max_bytes = max_bytes };
}

pub fn reserve(self: *Quota, bytes: usize) ?Reservation {
    var current = self.reserved.load(.monotonic);

    while (bytes <= self.max_bytes -| current) {
        if (self.reserved.cmpxchgWeak(current, current + bytes, .monotonic, .monotonic)) |observed| {
            current = observed;
            continue;
        }

        return .{ .quota = self, .bytes = bytes };
    }

    return null;
}

pub fn used(self: *const Quota) usize {
    return self.reserved.load(.monotonic);
}
