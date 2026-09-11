const Command = @This();
const source_namespace = @import("model.zig");
const CallbackRef = @import("CallbackRef.zig");
const std = @import("std");
const Argument = struct {
    offset: u16 = 0,
    len: u16 = 0,
};

generation: u64,
bytes: [source_namespace.max_command_bytes]u8 = @splat(0),
byte_len: u16 = 0,
arguments: [source_namespace.max_command_args]Argument = @splat(.{}),
argument_count: u8 = 0,
interval_ns: u64,
timeout_ms: u32,
render: ?CallbackRef = null,

pub fn appendArgument(command: *Command, argument_value: []const u8) !void {
    if (command.argument_count == source_namespace.max_command_args) {
        return error.TooManyBarCommandArguments;
    }
    if ((command.argument_count == 0 and argument_value.len == 0) or std.mem.indexOfScalar(u8, argument_value, 0) != null) {
        return error.InvalidBarCommandArgument;
    }

    const end = @as(usize, command.byte_len) + argument_value.len;
    if (argument_value.len > std.math.maxInt(u16) or end > command.bytes.len) {
        return error.BarCommandTooLong;
    }

    command.arguments[command.argument_count] = .{
        .offset = command.byte_len,
        .len = @intCast(argument_value.len),
    };
    @memcpy(command.bytes[command.byte_len..end], argument_value);
    command.byte_len = @intCast(end);
    command.argument_count += 1;
}

pub fn argument(command: *const Command, index: usize) ?[]const u8 {
    if (index >= command.argument_count) {
        return null;
    }

    const reference = command.arguments[index];
    return command.bytes[reference.offset..][0..reference.len];
}

pub fn argumentSlice(command: *const Command, storage: *[source_namespace.max_command_args][]const u8) []const []const u8 {
    for (0..command.argument_count) |index| {
        storage[index] = command.argument(index).?;
    }

    return storage[0..command.argument_count];
}
