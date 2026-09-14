//! The short age a card shows beside its workspace: how long the current
//! status has held, in the coarsest unit that is not zero.
const std = @import("std");

pub const max_bytes = 8;

/// Working durations retain seconds during the first minute.
/// Example: `const elapsed = age_label.duration(10, &buffer); // "10s"`
pub fn duration(seconds: u32, buffer: *[max_bytes]u8) []const u8 {
    if (seconds < 60) {
        return std.fmt.bufPrint(buffer, "{d}s", .{seconds}) catch unreachable;
    }

    return format(seconds, buffer);
}

/// Formats seconds as `now`, `3m`, `2h` or `1d`.
/// Example: `const age = age_label.format(190, &buffer); // "3m"`
pub fn format(seconds: u32, buffer: *[max_bytes]u8) []const u8 {
    if (seconds < 60) {
        return "now";
    }

    if (seconds < 3600) {
        return std.fmt.bufPrint(buffer, "{d}m", .{seconds / 60}) catch unreachable;
    }

    if (seconds < 86400) {
        return std.fmt.bufPrint(buffer, "{d}h", .{seconds / 3600}) catch unreachable;
    }

    return std.fmt.bufPrint(buffer, "{d}d", .{@min(seconds / 86400, 9999)}) catch unreachable;
}

test "ages pick the coarsest non-zero unit" {
    var buffer: [max_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("0s", duration(0, &buffer));
    try std.testing.expectEqualStrings("10s", duration(10, &buffer));
    try std.testing.expectEqualStrings("59s", duration(59, &buffer));
    try std.testing.expectEqualStrings("1m", duration(60, &buffer));
    try std.testing.expectEqualStrings("1h", duration(3600, &buffer));
    try std.testing.expectEqualStrings("now", format(0, &buffer));
    try std.testing.expectEqualStrings("now", format(59, &buffer));
    try std.testing.expectEqualStrings("1m", format(60, &buffer));
    try std.testing.expectEqualStrings("3m", format(190, &buffer));
    try std.testing.expectEqualStrings("59m", format(3599, &buffer));
    try std.testing.expectEqualStrings("2h", format(2 * 3600 + 59, &buffer));
    try std.testing.expectEqualStrings("1d", format(86400, &buffer));
    try std.testing.expectEqualStrings("9999d", format(std.math.maxInt(u32), &buffer));
}
