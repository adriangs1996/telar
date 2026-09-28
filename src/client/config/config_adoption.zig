//! Configuration reload: schedules the file watch, adopts a validated
//! generation and reports the configuration to the user.
const data = @import("model");
const core = @import("telar-core");
const std = @import("std");
const config_reload = @import("../resources/config_reload.zig");
const config_queries = @import("config_queries.zig");
const bar_updates = @import("bar_updates.zig");
const client_diagnostic = @import("client_diagnostic.zig");
const Snapshot = @import("Snapshot.zig");
const Adoption = @import("../resources/Adoption.zig");
const notifications = @import("../notifications/notifications.zig");
const pane_resize = @import("../panes/pane_resize.zig");
const sidebar_toggle = @import("../workspace/sidebar_toggle.zig");
const Client = @import("../execution/Client.zig");

/// Selects the live configuration resources before scheduling their next watch.
/// No configured file means no watch; incomplete ownership is an explicit error.
/// Example: `try config_adoption.scheduleConfigReload(client);`
pub fn scheduleConfigReload(client: *Client) !void {
    const path = client.options.config_path orelse return;
    const trust_path = client.options.trust_path orelse return error.ConfigurationNotLoaded;
    const generation = client.lua_generation orelse return error.ConfigurationNotLoaded;
    const registry = client.plugin_registry orelse return error.ConfigurationNotLoaded;

    try client.to_background.push(config_reload.schedule(
        &client.reload,
        .{
            .io = client.io,
            .gpa = client.gpa,
            .path = path,
            .profile = client.options.profile,
            .trust_path = trust_path,
            .current_generation = generation,
            .current_registry = registry,
        },
    ));
}

/// Resolves one reload completion, applies its outcome and rearms the watcher.
/// Example: `_ = try config_adoption.completeConfigReload(app, result);`
pub fn completeConfigReload(client: *Client, result: anyerror!config_reload.ConfigReload) !data.ConfigReloadOutcome {
    const reload = try result;
    const outcome: data.ConfigReloadOutcome = switch (config_reload.resolve(
        &client.reload,
        .{
            .gpa = client.gpa,
            .reload = reload,
            .checks = .{
                .kitty_support = client.model.host.host_capabilities.images,
                .sidebar_renderer_locked = client.options.sidebar_renderer_locked,
                .current_sidebar = client.model.config.sidebar_rendering,
            },
        },
    )) {
        .unchanged => .unchanged,
        .rejected => |diagnostic| rejected: {
            _ = try client_diagnostic.replace(
                &client.model,
                .{
                    .diagnostic = diagnostic,
                    .invalid_fallback = client_diagnostic.formatted(
                        "configuration reload failed: invalid diagnostic text",
                        .{},
                    ),
                },
            );
            try notifications.publishNotificationNow(
                client,
                .{
                    .level = .failure,
                    .title = "Configuration rejected",
                    .message = data.client_diagnostic.shown(&client.model) orelse return error.ClientDiagnosticMissing,
                    .duration_ns = 7 * std.time.ns_per_s,
                },
            );
            break :rejected .rejected;
        },
        .adopted => |adoption| adopted: {
            const commit = try adoptConfiguration(client, adoption);
            try notifications.publishNotificationNow(
                client,
                .{
                    .level = .success,
                    .title = "Configuration reloaded",
                    .message = "The new settings are active",
                },
            );
            break :adopted .{
                .adopted = commit,
            };
        },
    };
    try scheduleConfigReload(client);
    return outcome;
}

/// Adopts one validated generation through the client application boundary.
/// The client settings one configuration snapshot selects.
pub fn configFrom(snapshot: *const Snapshot) data.Config {
    return .{
        .notification_delivery = snapshot.notification_delivery,
        .history_show_agent_commands = snapshot.history_show_agent_commands,
        .history_enter_runs = snapshot.history_enter_runs,
        .history_match_fts = snapshot.history_match_fts,
        .themes = .{
            .light = snapshot.theme_light,
            .dark = snapshot.theme_dark,
        },
    };
}

fn adoptConfiguration(client: *Client, adoption: Adoption) !data.ConfigurationCommit {
    var consumed = false;
    errdefer if (!consumed) adoption.deinit(client.gpa);
    const snapshot = &adoption.generation.snapshot;
    const commit = try data.config_reload.apply(&client.model, 
        .{
            .generation = adoption.generation.number,
            .sidebar_visible = snapshot.sidebar_visible,
            .pane_gaps = snapshot.pane_gaps,
            .window_title = snapshot.windowTitle(),
            .bars = snapshot.bars.presentation(),
            .config = configFrom(snapshot),
        },
    );
    _ = data.client_diagnostic.clear(&client.model);
    std.debug.assert(adoption.generation.number == commit.generation);
    const previous_generation = client.lua_generation;
    const previous_registry = client.plugin_registry;
    const previous_trust = client.trust_store;

    client.lua_generation = adoption.generation;
    client.plugin_registry = adoption.registry;
    client.trust_store = adoption.trust_store;
    client.model.to_host.rebind_input = true;
    client.model.config.sidebar_rendering = adoption.sidebar_rendering;
    client.model.sound_playback.configure(snapshot.sound);
    consumed = true;

    if (previous_generation) |generation| {
        generation.deinit();
    }
    if (previous_registry) |registry| {
        client.gpa.destroy(registry);
    }
    if (previous_trust) |trust| {
        client.gpa.destroy(trust);
    }
    if (commit.bars_changed) {
        try bar_updates.synchronizeBars(client);
    }
    if (!client.options.theme_locked) {
        client.model.theme = snapshot.resolveTheme(client.model.host.host_capabilities.appearance, null);
    }
    client.model.icon_theme = snapshot.icon_theme;
    if (commit.sidebar) |sidebar| {
        try sidebar_toggle.deliverSidebarLayout(client, sidebar);
    } else if (commit.pane_gaps_changed) {
        client.model.to_host.invalidate_placements = true;
        if (client.model.tabs.activeSlot()) |tab| {
            try pane_resize.resizeAttachedPanes(client, tab, client.geometry().area);
        }
    }

    std.debug.assert(consumed);

    return commit;
}

/// Requests an unconditional load on the next normal worker cycle. Example: `try config_reloads.request(client);`
pub fn requestConfigReload(client: *Client) !void {
    if (client.options.config_path == null or client.options.trust_path == null or client.lua_generation == null or client.plugin_registry == null) {
        return error.ConfigurationNotLoaded;
    }

    client.reload.force_next = true;
}

/// Reads adopted values without executing Lua. Example: `try config_queries.show(client, reply);`
pub fn showConfiguration(client: *Client, reply: *core.ClientCommand) !void {
    const section = if (reply.length == 0) config_queries.Section.client else std.meta.stringToEnum(config_queries.Section, reply.text()) orelse return error.UnknownConfigurationSection;
    const generation = client.lua_generation orelse return error.ConfigurationNotLoaded;
    var writer = std.Io.Writer.fixed(&reply.bytes);
    if (section == .client) {
        try std.json.Stringify.value(
            .{
                .source = client.options.config_path,
                .profile = client.options.profile,
                .generation = client.model.configuration_generation,
                .sidebar_visible = client.model.sidebar_visible,
                .sidebar_width = client.model.sidebar_width,
                .workspace_list_collapsed = client.model.workspace_list_collapsed,
                .pane_gaps = client.model.pane_gaps,
                .window_title = data.config_reload.windowTitleTemplate(&client.model),
                .sound = generation.snapshot.sound,
                .notification_delivery = generation.snapshot.notification_delivery,
                .history_show_agent_commands = generation.snapshot.history_show_agent_commands,
                .history_enter_runs = generation.snapshot.history_enter_runs,
                .history_match_fts = generation.snapshot.history_match_fts,
                .sections = [_][]const u8{
                    "client",
                    "theme",
                    "gui",
                    "input",
                    "runtime",
                    "binding",
                },
            },
            .{},
            &writer,
        );
    } else {
        try config_queries.writeSection(
            &generation.snapshot,
            .{
                .section = section,
                .index = std.math.cast(usize, reply.value) orelse return error.InvalidIndex,
            },
            &writer,
        );
    }

    reply.length = @intCast(writer.buffered().len);
    reply.status = .applied;
}
