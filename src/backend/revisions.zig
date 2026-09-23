//! Change counters that consumers compare against the last value they saw.
//! Zero stays reserved for "never seen", so a counter wraps to one.

const std = @import("std");

/// Advances one revision counter, skipping zero on wrap.
///
/// ```zig
/// revisions.advance(&pane.cell_revision);
/// ```
pub fn advance(value: *u64) void {
    value.* +%= 1;

    if (value.* == 0) {
        value.* = 1;
    }
}

test "a revision wraps to one, never to the unseen zero" {
    var value: u64 = std.math.maxInt(u64);
    advance(&value);
    try std.testing.expectEqual(@as(u64, 1), value);

    advance(&value);
    try std.testing.expectEqual(@as(u64, 2), value);
}
