const std = @import("std");
/// Iterates the NUL-terminated arguments of a pane record.
///
/// ```zig
/// var arguments = ArgumentIterator.init(record.arguments);
/// while (arguments.next()) |argument| use(argument);
/// ```
const ArgumentIterator = @This();

remaining: []const u8,

pub fn init(arguments: []const u8) ArgumentIterator {
    return .{ .remaining = arguments };
}

pub fn next(self: *ArgumentIterator) ?[]const u8 {
    if (self.remaining.len == 0) {
        return null;
    }
    const end = std.mem.indexOfScalar(u8, self.remaining, 0) orelse self.remaining.len;
    const argument = self.remaining[0..end];
    self.remaining = if (end < self.remaining.len) self.remaining[end + 1 ..] else self.remaining[end..];
    return argument;
}
