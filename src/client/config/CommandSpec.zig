/// One configured subprocess: a bounded argv plus its deadline.
const data = @import("model");
const CommandSpec = @This();

bytes: [data.config_values.max_agent_description_command_bytes]u8 = undefined,
byte_len: u16 = 0,
offsets: [data.config_values.max_agent_description_command_args]u16 = @splat(0),
lengths: [data.config_values.max_agent_description_command_args]u16 = @splat(0),
argument_count: u8 = 0,
timeout_ms: u32 = data.config_values.default_agent_description_timeout_ms,

pub fn enabled(command: *const CommandSpec) bool {
    return command.argument_count != 0;
}

pub fn argument(command: *const CommandSpec, index: usize) ?[]const u8 {
    if (index >= command.argument_count) {
        return null;
    }
    const start = command.offsets[index];
    return command.bytes[start .. start + command.lengths[index]];
}

pub fn arguments(command: *const CommandSpec, storage: *[data.config_values.max_agent_description_command_args][]const u8) []const []const u8 {
    for (0..command.argument_count) |index| storage[index] = command.argument(index).?;
    return storage[0..command.argument_count];
}
