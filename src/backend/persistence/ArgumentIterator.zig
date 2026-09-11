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

pub fn next(iterator: *ArgumentIterator) ?[]const u8 {
    if (iterator.remaining.len == 0) {
        return null;
    }
    const end = std.mem.indexOfScalar(u8, iterator.remaining, 0) orelse iterator.remaining.len;
    const argument = iterator.remaining[0..end];
    iterator.remaining = if (end < iterator.remaining.len) iterator.remaining[end + 1 ..] else iterator.remaining[end..];
    return argument;
}
