const std = @import("std");
const core = @import("telar-core");
const Client = @import("../../AttachedClient.zig");
const ConfiguredPlugins = @import("../../plugins/ConfiguredPlugins.zig");

/// Reads one bounded catalog page from the adopted generation. Example: `try plugin_queries.list(client, reply);`
pub fn list(client: *Client, reply: *core.ClientCommand) !void {
    const generation = client.lua_generation orelse return error.ConfigurationNotLoaded;
    if (reply.target_id != 0 and reply.target_id != generation.number) {
        return error.StaleConfiguration;
    }

    const registry = client.plugin_registry orelse return error.PluginRegistryUnavailable;
    const catalog: ConfiguredPlugins = .{ .snapshot = &generation.snapshot, .registry = registry };
    const index = std.math.cast(usize, reply.value) orelse return error.InvalidPage;
    const count = generation.snapshot.plugin_count;
    if (index > count) {
        return error.InvalidPage;
    }

    var writer = std.Io.Writer.fixed(&reply.bytes);
    try writer.print("{{\"generation\":{d},\"entries\":[", .{generation.number});
    if (index < count) {
        const spec = &generation.snapshot.plugins[index];
        const package = catalog.package(index);
        try std.json.Stringify.value(.{ .index = index, .path = spec.path(), .id = if (package) |loaded| loaded.manifest.id() else null, .version = if (package) |loaded| loaded.manifest.version() else null, .enabled = spec.enabled }, .{}, &writer);
    }

    try writer.writeAll("]}");
    reply.length = @intCast(writer.buffered().len);
    reply.value = if (index + 1 < count) @intCast(index + 1) else -1;
    reply.status = .applied;
}
