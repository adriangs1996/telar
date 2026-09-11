const Cursor = @This();

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
