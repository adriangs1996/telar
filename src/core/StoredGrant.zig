const StoredGrant = @This();
const source_namespace = @import("plugin.zig");
const Grant = @import("Grant.zig");
plugin_bytes: [source_namespace.max_id_bytes]u8 = undefined,
plugin_len: u8,
grant: Grant,

pub fn pluginId(stored: *const StoredGrant) []const u8 {
    return stored.plugin_bytes[0..stored.plugin_len];
}
