const Quota = @This();
const std = @import("std");
const Reservation = @import("Reservation.zig");
max_bytes: usize,
reserved: std.atomic.Value(usize) = .init(0),

pub fn init(max_bytes: usize) Quota {
    return .{ .max_bytes = max_bytes };
}

pub fn reserve(quota: *Quota, bytes: usize) ?Reservation {
    var current = quota.reserved.load(.monotonic);

    while (bytes <= quota.max_bytes -| current) {
        if (quota.reserved.cmpxchgWeak(current, current + bytes, .monotonic, .monotonic)) |observed| {
            current = observed;
            continue;
        }

        return .{ .quota = quota, .bytes = bytes };
    }

    return null;
}

pub fn used(quota: *const Quota) usize {
    return quota.reserved.load(.monotonic);
}
