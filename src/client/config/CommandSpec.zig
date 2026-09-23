/// One configured subprocess: a bounded argv plus its deadline.
const data = @import("model");
const CommandSpec = @This();

bytes: [data.config_values.max_agent_description_command_bytes]u8 = undefined,
byte_len: u16 = 0,
offsets: [data.config_values.max_agent_description_command_args]u16 = @splat(0),
lengths: [data.config_values.max_agent_description_command_args]u16 = @splat(0),
argument_count: u8 = 0,
timeout_ms: u32 = data.config_values.default_agent_description_timeout_ms,

pub fn enabled(self: *const CommandSpec) bool {
    return self.argument_count != 0;
}

pub fn argument(self: *const CommandSpec, index: usize) ?[]const u8 {
    if (index >= self.argument_count) {
        return null;
    }
    const start = self.offsets[index];
    return self.bytes[start .. start + self.lengths[index]];
}

pub fn arguments(self: *const CommandSpec, storage: *[data.config_values.max_agent_description_command_args][]const u8) []const []const u8 {
    for (0..self.argument_count) |index| storage[index] = self.argument(index).?;
    return storage[0..self.argument_count];
}
