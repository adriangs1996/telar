//! Shared access to the client's awake monotonic clock.

const std = @import("std");

/// Returns the current awake-clock timestamp as nonnegative nanoseconds.
///
/// ```zig
/// const now_ns = monotonic(io);
/// ```
pub fn monotonic(io: std.Io) u64 {
    const timestamp = std.Io.Timestamp.now(io, .awake);

    return @intCast(@max(timestamp.nanoseconds, 0));
}

test "monotonic timestamps never move backwards" {
    const first = monotonic(std.testing.io);
    const second = monotonic(std.testing.io);

    try std.testing.expect(second >= first);
}
