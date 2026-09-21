//! Adapts asynchronous configuration reloads to one client's application state.

const client_diagnostic = @import("../../application/configuration/client_diagnostic.zig");
const Client = @import("../../AttachedClient.zig");
const reload_worker = @import("../../resources/config_reload.zig");
const Outcome = @import("../../application/configuration/config_reload_delivery.zig").Outcome;
const DeliveryContext = @import("DeliveryContext.zig");
const ResolutionType = @import("../../application/configuration/config_reload_delivery.zig").Resolution;
const Adoption = @import("../../resources/Adoption.zig");
const ConfigurationCommitType = @import("../../model/ConfigurationCommit.zig");
const AdoptionContext = @import("AdoptionContext.zig");
const std = @import("std");
const bar_updates = @import("bar_updates.zig");
const sidebar_projection = @import("../notifications/sidebar_projection.zig");
const pane_geometry = @import("../panes/pane_geometry.zig");
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
        .watcher = client.config_watcher,
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
            .current_sidebar = client.chrome.sidebarRenderer(),
        },
    })) {
        .unchanged => .unchanged,
        .rejected => |diagnostic| .{ .rejected = diagnostic },
        .adopted => |adoption| adopted: {
            context.adoption = adoption;
            break :adopted .adopted;
        },
    };
    const outcome: Outcome = switch (resolution) {
        .unchanged => .unchanged,
        .rejected => |diagnostic| rejected: {
            _ = try client_diagnostic.replace(&client.model, .{
                .diagnostic = diagnostic,
                .invalid_fallback = client_diagnostic.formatted("configuration reload failed: invalid diagnostic text", .{}),
            });
            try notification_flow.publishNow(client, .{
                .level = .failure,
                .title = "Configuration rejected",
                .message = client.model.diagnostic() orelse return error.ClientDiagnosticMissing,
                .duration_ns = 7 * std.time.ns_per_s,
            });
            break :rejected .rejected;
        },
        .adopted => adopted: {
            const adoption = context.adoption orelse return error.ConfigReloadAdoptionMissing;
            context.adoption = null;
            const commit = try apply(client, adoption);
            try notification_flow.publishNow(client, .{
                .level = .success,
                .title = "Configuration reloaded",
                .message = "The new settings are active",
            });
            break :adopted .{ .adopted = commit };
        },
    };
    try schedule(client);
    return outcome;
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
    const snapshot = &adoption.generation.snapshot;
    const commit = try client.model.applyConfiguration(.{
        .generation = adoption.generation.number,
        .sidebar_visible = snapshot.sidebar_visible,
        .pane_gaps = snapshot.pane_gaps,
        .window_title = snapshot.windowTitle(),
        .bars = snapshot.bars.presentation(),
    });
    _ = client.model.clearDiagnostic();
    std.debug.assert(context.adoption.generation.number == commit.generation);
    context.swap();
    if (commit.bars_changed) {
        try bar_updates.synchronize(client);
    }
    if (!client.options.theme_locked) {
        client.chrome.setTheme(snapshot.resolveTheme(client.model.hostCapabilities().appearance, null));
    }
    client.chrome.setIconTheme(snapshot.icon_theme);
    const host_size = client.model.hostSize();
    try client.chrome.configureSidebar(.{
        .support = client.model.hostCapabilities().images,
        .cell_width = host_size.cell_width_px,
        .cell_height = host_size.cell_height_px,
    });
    if (commit.sidebar) |sidebar| {
        try sidebar_projection.apply(client, sidebar);
    } else if (commit.pane_gaps_changed) {
        client.host_graphics.invalidatePlacements();
        try pane_geometry.offerActive(client, client.geometry().area);
    }

    std.debug.assert(context.consumed);

    return commit;
}

/// Requests an unconditional load on the next normal worker cycle. Example: `try config_reloads.request(client);`
pub fn request(client: *Client) !void {
    if (client.options.config_path == null or client.options.trust_path == null or client.lua_generation == null or client.plugin_registry == null) {
        return error.ConfigurationNotLoaded;
    }

    client.reload.force_next = true;
}
