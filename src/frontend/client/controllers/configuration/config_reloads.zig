//! Adapts asynchronous configuration reloads to one client's application state.

const Client = @import("../../Client.zig");
const reload_worker = @import("../../resources/config_reload.zig");
const Outcome = @import("telar-client").Outcome;
const DeliveryContext = @import("DeliveryContext.zig");
const ResolutionType = @import("telar-client").Resolution;
const DeliverConfigReloadHandlerType = @import("telar-client").DeliverConfigReloadHandler;
const Adoption = @import("../../resources/Adoption.zig");
const ConfigurationCommitType = @import("telar-client").ConfigurationCommit;
const AdoptionContext = @import("AdoptionContext.zig");
const ApplyConfigHandlerType = @import("telar-client").ApplyConfigHandler;
const std = @import("std");
const bar_updates = @import("bar_updates.zig");
const SidebarLayoutType = @import("telar-client").SidebarLayout;
const sidebar_projection = @import("../notifications/sidebar_projection.zig");
const kitty_delivery = @import("../../../graphics/kitty_delivery.zig");
const pane_geometry = @import("../panes/pane_geometry.zig");
const InputType = @import("telar-client").NotificationInput;
const notification_flow = @import("../notifications/notifications.zig");

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
    const resolution: ResolutionType = switch (reload_worker.resolve(&client.reload, .{
        .gpa = client.gpa,
        .reload = reload,
        .checks = .{
            .kitty_support = client.model.hostCapabilities().images,
            .sidebar_renderer_locked = client.options.sidebar_renderer_locked,
            .current_sidebar = client.sidebar_rendering,
        },
    })) {
        .unchanged => .unchanged,
        .rejected => |diagnostic| .{ .rejected = diagnostic },
        .adopted => |adoption| adopted: {
            context.adoption = adoption;
            break :adopted .adopted;
        },
    };
    var use_case: DeliverConfigReloadHandlerType = .{
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

/// Adopts one validated generation through the client application boundary.
///
/// ```zig
/// const commit = try apply(client, adoption);
/// ```
pub fn apply(client: *Client, adoption: Adoption) !ConfigurationCommitType {
    var context: AdoptionContext = .{
        .client = client,
        .adoption = adoption,
    };
    errdefer context.releaseOwned();
    var use_case: ApplyConfigHandlerType = .{
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

fn adoptResources(raw_context: *anyopaque, commit: ConfigurationCommitType) void {
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
            .support = client.model.hostCapabilities().images,
            .cell_width = host_size.cell_width_px,
            .cell_height = host_size.cell_height_px,
        },
    );
}

fn applySidebar(raw_context: *anyopaque, change: SidebarLayoutType) !void {
    const context: *AdoptionContext = @ptrCast(@alignCast(raw_context));
    try sidebar_projection.apply(context.client, change);
}

fn invalidateGraphicsPlacements(raw_context: *anyopaque) void {
    const context: *AdoptionContext = @ptrCast(@alignCast(raw_context));

    kitty_delivery.invalidatePlacements(&context.client.graphics_store);
}

fn offerActivePaneGeometry(raw_context: *anyopaque) !void {
    const context: *AdoptionContext = @ptrCast(@alignCast(raw_context));

    try pane_geometry.offerActive(context.client, context.client.geometry().area);
}

fn applyAdoption(raw_context: *anyopaque) !ConfigurationCommitType {
    const context: *DeliveryContext = @ptrCast(@alignCast(raw_context));
    const adoption = context.adoption orelse return error.ConfigReloadAdoptionMissing;
    // `apply` either installs the concrete owners or releases them on failure.
    context.adoption = null;

    return apply(context.client, adoption);
}

fn publishNotification(raw_context: *anyopaque, input: InputType) !void {
    const context: *DeliveryContext = @ptrCast(@alignCast(raw_context));

    try notification_flow.publishNow(context.client, input);
}

fn rearm(raw_context: *anyopaque) !void {
    const context: *DeliveryContext = @ptrCast(@alignCast(raw_context));

    try schedule(context.client);
}
