const Client = @import("../../Client.zig");
const AdoptionType = @import("../../resources/Adoption.zig");
const AdoptionContext = @This();

client: *Client,
adoption: AdoptionType,
consumed: bool = false,

pub fn releaseOwned(context: *AdoptionContext) void {
    if (!context.consumed) {
        context.adoption.deinit(context.client.gpa);
    }
}

pub fn swap(context: *AdoptionContext) void {
    const client = context.client;
    const snapshot = &context.adoption.generation.snapshot;
    const previous_generation = client.lua_generation;
    const previous_registry = client.plugin_registry;
    const previous_trust = client.trust_store;

    client.lua_generation = context.adoption.generation;
    client.plugin_registry = context.adoption.registry;
    client.trust_store = context.adoption.trust_store;
    client.host_input.replaceRouter(client.io, context.adoption.router);
    client.sidebar_rendering = context.adoption.sidebar_rendering;
    client.sound_playback.configure(snapshot.sound);
    client.notification_delivery = snapshot.notification_delivery;
    client.history_show_agent_commands = snapshot.history_show_agent_commands;
    client.history_enter_runs = snapshot.history_enter_runs;
    client.history_match_fts = snapshot.history_match_fts;
    client.appearance_themes = .{ .light = snapshot.theme_light, .dark = snapshot.theme_dark };
    context.consumed = true;

    if (previous_generation) |generation| {
        generation.deinit();
    }
    if (previous_registry) |registry| {
        client.gpa.destroy(registry);
    }
    if (previous_trust) |trust| {
        client.gpa.destroy(trust);
    }
}
