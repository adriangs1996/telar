const core = @import("telar-core");
const PluginAction = @import("../../input/PluginAction.zig");
const Client = @import("../../AttachedClient.zig");
const ConfiguredPlugins = @import("../../plugins/ConfiguredPlugins.zig");
const plugin_actions = @import("plugin_actions.zig");

/// Schedules an existing declared action with normal capability checks. Example: `try plugin_invocations.run(client, reply);`
pub fn run(client: *Client, reply: *core.ClientCommand) !void {
    const generation = client.lua_generation orelse return error.ConfigurationNotLoaded;
    const registry = client.plugin_registry orelse return error.PluginRegistryUnavailable;
    const catalog: ConfiguredPlugins = .{ .snapshot = &generation.snapshot, .registry = registry };
    const index = try catalog.find(reply.text());
    const package = catalog.package(index) orelse return error.PluginDisabled;
    const requested: PluginAction = .{ .plugin = core.stableId(package.manifest.id()), .action = reply.target_id };
    _ = try registry.resolve(requested);
    switch (try plugin_actions.start(client, requested, client.model.callbackContext())) {
        .started => reply.status = .admitted,
        .busy => return error.PluginWorkerBusy,
        .unavailable => return error.PluginWorkerUnavailable,
        .rejected => |err| return err,
    }
}
