const model = @import("model.zig");
const PluginSpec = @This();

path_bytes: [model.max_plugin_path_bytes]u8 = undefined,
path_len: u16,
enabled: bool = true,

pub fn path(self: *const PluginSpec) []const u8 {
    return self.path_bytes[0..self.path_len];
}
