//! Sequential borrowed argv access; each grammar chooses its own errors.

const std = @import("std");

pub const Cursor = @import("Cursor.zig");

test "cursor consumes option-shaped values once and preserves missing-value errors" {
    var cursor: Cursor = .{ .remaining = &.{ "--socket", "--literal-value" } };
    try std.testing.expectEqualStrings("--socket", std.mem.span(cursor.next().?));
    try std.testing.expectEqualStrings("--literal-value", std.mem.span(try cursor.require(error.MissingSocketPath)));
    try std.testing.expectError(error.MissingSocketPath, cursor.require(error.MissingSocketPath));
    try std.testing.expect(cursor.next() == null);
}
