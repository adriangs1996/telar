/// Input state only the adapter holds: it decodes replayed host bytes for a
/// prompt.
const HostInputSource = @This();

context: *anyopaque,
route_prompt_bytes_fn: *const fn (*anyopaque, []const u8) anyerror!void,

/// Decodes replayed host bytes for the active prompt.
pub fn routePromptBytes(self: HostInputSource, bytes: []const u8) !void {
    return self.route_prompt_bytes_fn(self.context, bytes);
}
