//! The short age a card shows beside its workspace: how long the current
//! status has held, in the coarsest unit that is not zero.
const std = @import("std");

pub const max_bytes = 8;

/// Working durations retain seconds during the first minute.
/// Example: `const elapsed = age_label.duration(10, &buffer); // "10s"`
pub fn duration(seconds: u32, buffer: *[max_bytes]u8) []const u8 {
    if (seconds < 60) {
        // SAFETY: seconds is below 60 here, so the label needs at most three of max_bytes bytes.
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
        // SAFETY: minutes is below 60 here, so the label needs at most three of max_bytes bytes.
        return std.fmt.bufPrint(buffer, "{d}m", .{seconds / 60}) catch unreachable;
    }

    if (seconds < 86400) {
        // SAFETY: hours is below 24 here, so the label needs at most three of max_bytes bytes.
        return std.fmt.bufPrint(buffer, "{d}h", .{seconds / 3600}) catch unreachable;
    }

    // SAFETY: the day count is capped at four digits; its suffix keeps the label within max_bytes.
    return std.fmt.bufPrint(buffer, "{d}d", .{@min(seconds / 86400, 9999)}) catch unreachable;
}
