const core = @import("telar-core");
const Client = @import("../../AttachedClient.zig");
const ConfiguredPlugins = @import("../../plugins/ConfiguredPlugins.zig");
const PluginOverride = @import("../../resources/PluginOverride.zig");

/// Queues enablement through the configuration worker. Example: `try plugin_toggles.enable(client, reply);`
pub fn enable(client: *Client, reply: *core.ClientCommand) !void {
    try request(client, reply, true);
}

fn request(client: *Client, reply: *core.ClientCommand, enabled: bool) !void {
    const generation = client.lua_generation orelse return error.ConfigurationNotLoaded;
    const registry = client.plugin_registry orelse return error.PluginRegistryUnavailable;
    if (client.options.config_path == null or client.options.trust_path == null) {
        return error.ConfigurationNotLoaded;
    }

    const catalog: ConfiguredPlugins = .{ .snapshot = &generation.snapshot, .registry = registry };
    const index = try catalog.find(reply.text());
    var override: PluginOverride = .{ .spec = generation.snapshot.plugins[index] };
    override.spec.enabled = enabled;
    if (catalog.package(index)) |package| {
        override.plugin_id = core.stableId(package.manifest.id());
    }

    try client.reload.plugin_overrides.set(override);
    client.reload.force_next = true;
    reply.status = .admitted;
}

/// Queues disablement and removal of the plugin's source bindings. Example: `try plugin_toggles.disable(client, reply);`
pub fn disable(client: *Client, reply: *core.ClientCommand) !void {
    try request(client, reply, false);
}
