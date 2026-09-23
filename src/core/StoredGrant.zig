const plugin = @import("plugin.zig");
const Grant = @import("Grant.zig");
const StoredGrant = @This();

plugin_bytes: [plugin.max_id_bytes]u8 = undefined,
plugin_len: u8,
grant: Grant,

pub fn pluginId(self: *const StoredGrant) []const u8 {
    return self.plugin_bytes[0..self.plugin_len];
}
