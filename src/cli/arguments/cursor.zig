//! Sequential borrowed argv access; each grammar chooses its own errors.

const std = @import("std");

pub const Cursor = struct {
    remaining: []const [*:0]const u8,

    /// Consumes one argument without interpreting option-shaped values.
    /// Example: `while (cursor.next()) |argument| parseOption(argument);`.
    pub fn next(cursor: *Cursor) ?[*:0]const u8 {
        if (cursor.remaining.len == 0) {
            return null;
        }

        const value = cursor.remaining[0];
        cursor.remaining = cursor.remaining[1..];
        return value;
    }

    /// Preserves the command's missing-value error rather than inventing one.
    /// Example: `options.socket = try cursor.require(error.MissingSocketPath);`.
    pub fn require(cursor: *Cursor, comptime missing: anyerror) ![*:0]const u8 {
        return cursor.next() orelse missing;
    }
};

test "cursor consumes option-shaped values once and preserves missing-value errors" {
    var cursor: Cursor = .{ .remaining = &.{ "--socket", "--literal-value" } };
    try std.testing.expectEqualStrings("--socket", std.mem.span(cursor.next().?));
    try std.testing.expectEqualStrings("--literal-value", std.mem.span(try cursor.require(error.MissingSocketPath)));
    try std.testing.expectError(error.MissingSocketPath, cursor.require(error.MissingSocketPath));
    try std.testing.expect(cursor.next() == null);
}
