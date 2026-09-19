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

/// Reads manifest metadata followed by individual action names. Example: `try plugin_queries.get(client, reply);`
pub fn get(client: *Client, reply: *core.ClientCommand) !void {
    const generation = client.lua_generation orelse return error.ConfigurationNotLoaded;
    if (reply.target_id != 0 and reply.target_id != generation.number) {
        return error.StaleConfiguration;
    }

    const registry = client.plugin_registry orelse return error.PluginRegistryUnavailable;
    const catalog: ConfiguredPlugins = .{ .snapshot = &generation.snapshot, .registry = registry };
    const index = try catalog.find(reply.text());
    const spec = &generation.snapshot.plugins[index];
    const package = catalog.package(index);
    const page = std.math.cast(usize, reply.value) orelse return error.InvalidPage;
    const action_count: usize = if (package) |loaded| loaded.manifest.action_count else 0;
    if (page > action_count) {
        return error.InvalidPage;
    }

    var writer = std.Io.Writer.fixed(&reply.bytes);
    try writer.print("{{\"generation\":{d},\"entries\":[", .{generation.number});
    if (page == 0) {
        if (package) |loaded| {
            var capabilities: [std.meta.fields(core.Capability).len][]const u8 = undefined;
            var count: usize = 0;
            var iterator = loaded.manifest.capabilities.iterator();
            while (iterator.next()) |capability| {
                capabilities[count] = capability.canonicalName();
                count += 1;
            }

            const digest = std.fmt.bytesToHex(loaded.digest, .lower);
            try std.json.Stringify.value(.{ .path = spec.path(), .enabled = spec.enabled, .id = loaded.manifest.id(), .version = loaded.manifest.version(), .entry = loaded.manifest.entry(), .source = loaded.manifest.source(), .revision = loaded.manifest.revision(), .digest = digest[0..], .capabilities = capabilities[0..count] }, .{}, &writer);
        } else {
            try std.json.Stringify.value(.{ .path = spec.path(), .enabled = spec.enabled, .id = @as(?[]const u8, null) }, .{}, &writer);
        }
    } else {
        try std.json.Stringify.value(package.?.manifest.actions[page - 1].slice(), .{}, &writer);
    }

    try writer.writeAll("]}");
    reply.length = @intCast(writer.buffered().len);
    reply.value = if (page < action_count) @intCast(page + 1) else -1;
    reply.status = .applied;
}
