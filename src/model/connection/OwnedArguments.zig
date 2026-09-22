//! Argument boundaries for bytes owned by one bounded outbox slot.
const core = @import("telar-core");
const std = @import("std");
const Self = @This();

lengths: [core.max_argument_count]u16 = undefined,
count: u16 = 0,

/// Copies transient argv into caller-owned storage before its source expires.
/// Example: `const arguments = try OwnedArguments.copy(argv, slot_bytes);`
pub fn copy(arguments: []const []const u8, bytes: []u8) !Self {
    if (arguments.len > core.max_argument_count) {
        return error.InvalidArgumentCount;
    }

    var self: Self = .{ .count = @intCast(arguments.len) };
    var offset: usize = 0;
    for (arguments, 0..) |argument, index| {
        if (argument.len > bytes.len - offset or argument.len > std.math.maxInt(u16) or std.mem.indexOfScalar(u8, argument, 0) != null) {
            return error.InvalidArguments;
        }

        @memcpy(bytes[offset..][0..argument.len], argument);
        self.lengths[index] = @intCast(argument.len);
        offset += argument.len;
    }

    return self;
}

/// Borrows stored argv only for synchronous wire encoding.
/// Example: `const argv = arguments.view(slot_bytes, &scratch);`
pub fn view(self: *const Self, bytes: []const u8, scratch: *[core.max_argument_count][]const u8) []const []const u8 {
    var offset: usize = 0;
    for (self.lengths[0..self.count], 0..) |length, index| {
        scratch[index] = bytes[offset..][0..length];
        offset += length;
    }

    return scratch[0..self.count];
}
