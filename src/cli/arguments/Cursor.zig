const Cursor = @This();

remaining: []const [*:0]const u8,

/// Consumes one argument without interpreting option-shaped values.
/// Example: `while (cursor.next()) |argument| parseOption(argument);`.
pub fn next(self: *Cursor) ?[*:0]const u8 {
    if (self.remaining.len == 0) {
        return null;
    }

    const value = self.remaining[0];
    self.remaining = self.remaining[1..];
    return value;
}

/// Preserves the command's missing-value error rather than inventing one.
/// Example: `options.socket = try cursor.require(error.MissingSocketPath);`.
pub fn require(self: *Cursor, comptime missing: anyerror) ![*:0]const u8 {
    return self.next() orelse missing;
}
