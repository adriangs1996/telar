const std = @import("std");

/// Fits the native history duration column without losing its unit.
/// Example: `const label = duration(entry.duration_ns, &storage);`.
pub fn duration(ns: i64, storage: []u8) []const u8 {
    const milliseconds = @divTrunc(@max(ns, 0), std.time.ns_per_ms);
    return if (milliseconds < 1000)
        std.fmt.bufPrint(storage, "{d}ms", .{milliseconds}) catch "?"
    else if (milliseconds < 60000)
        std.fmt.bufPrint(storage, "{d}.{d}s", .{ @divTrunc(milliseconds, 1000), @divTrunc(@mod(milliseconds, 1000), 100) }) catch "?"
    else if (milliseconds < 3600000)
        std.fmt.bufPrint(storage, "{d}m", .{@divTrunc(milliseconds, 60000)}) catch "?"
    else
        std.fmt.bufPrint(storage, "{d}h", .{@divTrunc(milliseconds, 3600000)}) catch "?";
}

/// Formats the age from the query's owned timestamp, requiring no clock read.
/// Example: `const label = age(state.now_ms -| entry.started_at_ms, &storage);`.
pub fn age(ms: i64, storage: []u8) []const u8 {
    const seconds = @divTrunc(@max(ms, 0), 1000);
    return if (seconds < 60)
        "now"
    else if (seconds < 3600)
        std.fmt.bufPrint(storage, "{d}m ago", .{@divTrunc(seconds, 60)}) catch "?"
    else if (seconds < 86400)
        std.fmt.bufPrint(storage, "{d}h ago", .{@divTrunc(seconds, 3600)}) catch "?"
    else
        std.fmt.bufPrint(storage, "{d}d ago", .{@divTrunc(seconds, 86400)}) catch "?";
}
