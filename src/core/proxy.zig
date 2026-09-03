//! Shared bounds and hostname ordering for the proxy configuration.

const std = @import("std");

pub const max_intercept_hosts = 256;
pub const max_hostname_bytes = 253;
pub const max_intercept_bytes = max_intercept_hosts * max_hostname_bytes;
pub const default_capture_part_bytes = 4 * 1024 * 1024;
pub const default_capture_exchange_bytes = 8 * 1024 * 1024;
pub const default_capture_total_bytes = 64 * 1024 * 1024;
pub const default_capture_join_timeout_ms = 30_000;

pub fn orderHostname(left: []const u8, right: []const u8) std.math.Order {
    const common_len = @min(left.len, right.len);
    for (left[0..common_len], right[0..common_len]) |left_byte, right_byte| {
        const left_lower = std.ascii.toLower(left_byte);
        const right_lower = std.ascii.toLower(right_byte);
        if (left_lower < right_lower) return .lt;
        if (left_lower > right_lower) return .gt;
    }
    return std.math.order(left.len, right.len);
}

test "proxy hostname ordering is ASCII case insensitive" {
    try std.testing.expectEqual(std.math.Order.eq, orderHostname("API.Example", "api.example"));
    try std.testing.expectEqual(std.math.Order.lt, orderHostname("a.example", "b.example"));
    try std.testing.expectEqual(std.math.Order.lt, orderHostname("api", "api.example"));
}
