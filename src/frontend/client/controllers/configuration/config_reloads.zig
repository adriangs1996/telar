//! Adapts asynchronous configuration reloads to one client's application state.

const std = @import("std");
const configuration_application = @import("../../application/configuration/root.zig");
const client_model = @import("../../model/root.zig");
const notifications = @import("../../../notifications/root.zig");
const bar_updates = @import("bar_updates.zig");
const notification_flow = @import("../notifications/notifications.zig");
const pane_geometry = @import("../panes/pane_geometry.zig");
const sidebar_projection = @import("../notifications/sidebar_projection.zig");

const Client = @import("../../client.zig");
const reload_worker = @import("../../resources/config_reload.zig");
const config_use_case = configuration_application.config_reload;
const config_delivery = configuration_application.config_reload_delivery;

pub const Adoption = reload_worker.Adoption;

pub const Outcome = config_delivery.Outcome;

/// Schedules the next reload attempt when this client owns a watched
/// configuration.
///
/// ```zig
/// try schedule(client);
/// ```
pub fn schedule(client: *Client) !void {
    const path = client.options.config_path orelse return;

    try reload_worker.schedule(&client.reload, .{
        .io = client.io,
        .gpa = client.gpa,
        .select = &client.select,
        .path = path,
        .profile = client.options.profile,
        .trust_path = client.options.trust_path.?,
        .current_generation = client.lua_generation.?,
        .current_registry = client.plugin_registry.?,
    });
}

/// Resolves one reload completion, applies its outcome and rearms the watcher.
///
/// ```zig
/// _ = try handle(client, result);
/// ```
pub fn handle(client: *Client, result: anyerror!reload_worker.ConfigReload) !Outcome {
    const reload = try result;
    var context: DeliveryContext = .{ .client = client };
    defer context.releaseOwned();
    const resolution: config_delivery.Resolution = switch (reload_worker.resolve(&client.reload, client.gpa, reload, .{
        .kitty_support = client.model.hostCapabilities().kitty_graphics,
        .sidebar_renderer_locked = client.options.sidebar_renderer_locked,
        .current_sidebar = client.sidebar_rendering,
    })) {
        .unchanged => .unchanged,
        .rejected => |diagnostic| .{ .rejected = diagnostic },
        .adopted => |adoption| adopted: {
            context.adoption = adoption;
            break :adopted .adopted;
        },
    };
    var use_case: config_delivery.DeliverConfigReloadHandler = .{
        .model = &client.model,
        .effects = .{
            .context = &context,
            .apply_adoption = applyAdoption,
            .publish_notification = publishNotification,
            .rearm = rearm,
        },
    };

    return use_case.execute(resolution);
}

const DeliveryContext = struct {
    client: *Client,
    adoption: ?Adoption = null,

    fn releaseOwned(context: *DeliveryContext) void {
        if (context.adoption) |adoption| {
            adoption.deinit(context.client.gpa);
        }
    }
};

/// Adopts one validated generation through the client application boundary.
///
/// ```zig
/// const commit = try apply(client, adoption);
/// ```
pub fn apply(client: *Client, adoption: Adoption) !client_model.ConfigurationCommit {
    var context: AdoptionContext = .{
        .client = client,
        .adoption = adoption,
    };
    errdefer context.releaseOwned();
    var use_case: config_use_case.ApplyConfigHandler = .{
        .model = &client.model,
        .effects = .{
            .context = &context,
            .adopt_resources = adoptResources,
            .synchronize_bars = synchronizeBars,
            .project_appearance = projectAppearance,
            .configure_sidebar = configureSidebar,
            .apply_sidebar = applySidebar,
            .invalidate_graphics_placements = invalidateGraphicsPlacements,
            .offer_active_pane_geometry = offerActivePaneGeometry,
        },
    };
    const snapshot = &adoption.generation.snapshot;
    const commit = try use_case.execute(.{
        .configuration = .{
            .generation = adoption.generation.number,
            .sidebar_visible = snapshot.sidebar_visible,
            .pane_gaps = snapshot.pane_gaps,
            .window_title = snapshot.windowTitle(),
            .bars = snapshot.bars.presentation(),
        },
        .theme_locked = client.options.theme_locked,
    });
    std.debug.assert(context.consumed);

    return commit;
}

const AdoptionContext = struct {
    client: *Client,
    adoption: Adoption,
    consumed: bool = false,

    fn releaseOwned(context: *AdoptionContext) void {
        if (!context.consumed) {
            context.adoption.deinit(context.client.gpa);
        }
    }

    fn swap(context: *AdoptionContext) void {
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
};

fn adoptResources(raw_context: *anyopaque, commit: client_model.ConfigurationCommit) void {
    const context: *AdoptionContext = @ptrCast(@alignCast(raw_context));
    std.debug.assert(context.adoption.generation.number == commit.generation);
    context.swap();
}

fn projectAppearance(raw_context: *anyopaque, apply_theme: bool) void {
    const context: *AdoptionContext = @ptrCast(@alignCast(raw_context));
    const snapshot = &context.adoption.generation.snapshot;

    if (apply_theme) {
        const appearance_theme: ?@TypeOf(snapshot.theme) = switch (context.client.model.hostCapabilities().appearance) {
            .unknown => null,
            .light => snapshot.theme_light,
            .dark => snapshot.theme_dark,
        };
        context.client.view.setTheme(appearance_theme orelse snapshot.theme);
    }
    context.client.view.setIconTheme(snapshot.icon_theme);
}

fn synchronizeBars(raw_context: *anyopaque) !void {
    const context: *AdoptionContext = @ptrCast(@alignCast(raw_context));

    try bar_updates.synchronize(context.client);
}

fn configureSidebar(raw_context: *anyopaque) !void {
    const context: *AdoptionContext = @ptrCast(@alignCast(raw_context));
    const client = context.client;
    const host_size = client.model.hostSize();

    try client.view.configureSidebar(
        client.sidebar_rendering,
        .{
            .support = client.model.hostCapabilities().kitty_graphics,
            .cell_width = host_size.cell_width_px,
            .cell_height = host_size.cell_height_px,
        },
    );
}

fn applySidebar(raw_context: *anyopaque, change: client_model.SidebarLayout) !void {
    const context: *AdoptionContext = @ptrCast(@alignCast(raw_context));
    try sidebar_projection.apply(context.client, change);
}

fn invalidateGraphicsPlacements(raw_context: *anyopaque) void {
    const context: *AdoptionContext = @ptrCast(@alignCast(raw_context));

    context.client.graphics_store.invalidatePlacements();
}

fn offerActivePaneGeometry(raw_context: *anyopaque) !void {
    const context: *AdoptionContext = @ptrCast(@alignCast(raw_context));

    try pane_geometry.offerActive(context.client, context.client.view.workbench());
}

fn applyAdoption(raw_context: *anyopaque) !client_model.ConfigurationCommit {
    const context: *DeliveryContext = @ptrCast(@alignCast(raw_context));
    const adoption = context.adoption orelse return error.ConfigReloadAdoptionMissing;
    // `apply` either installs the concrete owners or releases them on failure.
    context.adoption = null;

    return apply(context.client, adoption);
}

fn publishNotification(raw_context: *anyopaque, input: notifications.Input) !void {
    const context: *DeliveryContext = @ptrCast(@alignCast(raw_context));

    try notification_flow.publishNow(context.client, input);
}

fn rearm(raw_context: *anyopaque) !void {
    const context: *DeliveryContext = @ptrCast(@alignCast(raw_context));

    try schedule(context.client);
}
