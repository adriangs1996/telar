const model = @import("model.zig");
const Argument = @import("Argument.zig");
const CallbackRef = @import("CallbackRef.zig");
const std = @import("std");
const Command = @This();

generation: u64,
bytes: [model.max_command_bytes]u8 = @splat(0),
byte_len: u16 = 0,
arguments: [model.max_command_args]Argument = @splat(.{}),
argument_count: u8 = 0,
interval_ns: u64,
timeout_ms: u32,
render: ?CallbackRef = null,

pub fn appendArgument(self: *Command, argument_value: []const u8) !void {
    if (self.argument_count == model.max_command_args) {
        return error.TooManyBarCommandArguments;
    }
    if ((self.argument_count == 0 and argument_value.len == 0) or std.mem.indexOfScalar(u8, argument_value, 0) != null) {
        return error.InvalidBarCommandArgument;
    }

    const end = @as(usize, self.byte_len) + argument_value.len;
    if (argument_value.len > std.math.maxInt(u16) or end > self.bytes.len) {
        return error.BarCommandTooLong;
    }

    self.arguments[self.argument_count] = .{
        .offset = self.byte_len,
        .len = @intCast(argument_value.len),
    };
    @memcpy(self.bytes[self.byte_len..end], argument_value);
    self.byte_len = @intCast(end);
    self.argument_count += 1;
}

pub fn argument(self: *const Command, index: usize) ?[]const u8 {
    if (index >= self.argument_count) {
        return null;
    }

    const reference = self.arguments[index];
    return self.bytes[reference.offset..][0..reference.len];
}

pub fn argumentSlice(self: *const Command, storage: *[model.max_command_args][]const u8) []const []const u8 {
    for (0..self.argument_count) |index| {
        storage[index] = self.argument(index).?;
    }

    return storage[0..self.argument_count];
}
