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

/// Reserves up to `bytes`, as much as the quota has left, and returns how
/// many it reserved; zero when the quota is spent.
///
/// ```zig
/// const granted = quota.reserveAtMost(fragment.len);
/// ```
pub fn reserveAtMost(self: *Quota, bytes: usize) usize {
    var current = self.reserved.load(.monotonic);

    while (true) {
        const granted = @min(bytes, self.max_bytes -| current);
        if (granted == 0) {
            return 0;
        }

        if (self.reserved.cmpxchgWeak(current, current + granted, .monotonic, .monotonic)) |observed| {
            current = observed;
            continue;
        }

        return granted;
    }
}

pub fn used(self: *const Quota) usize {
    return self.reserved.load(.monotonic);
}
