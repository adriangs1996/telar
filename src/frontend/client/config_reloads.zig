//! Adapts asynchronous configuration reloads to one client's application state.

const std = @import("std");
const lua_config = @import("../config/root.zig");
const client_application = @import("application/root.zig");
const client_model = @import("model.zig");
const notification_flow = @import("notifications.zig");
const pane_geometry = @import("pane_geometry.zig");
const sidebar_projection = @import("sidebar_projection.zig");

const Client = @import("client.zig");
const client_diagnostics = @import("client_diagnostics.zig");
const reload_worker = @import("config_reload.zig");
const config_use_case = client_application.config_reload;

pub const Adoption = reload_worker.Adoption;

pub const Outcome = union(enum) {
    unchanged,
    rejected,
    adopted: client_model.ConfigurationCommit,
};

/// Schedules the next reload attempt when this client owns a watched
/// configuration.
///
/// ```zig
/// try schedule(client);
/// ```
pub fn schedule(client: *Client) !void {
    const path = client.options.config_path orelse return;

    try reload_worker.schedule(&client.reload, client.io, client.gpa, &client.select, .{
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
    const outcome: Outcome = switch (reload_worker.resolve(&client.reload, client.gpa, reload, .{
        .kitty_support = client.model.hostCapabilities().kitty_graphics,
        .sidebar_renderer_locked = client.options.sidebar_renderer_locked,
        .current_sidebar = client.sidebar_rendering,
    })) {
        .unchanged => .unchanged,
        .rejected => |diagnostic| rejected: {
            try commitDiagnostic(client, diagnostic);
            try notification_flow.publishDiagnostic(client, "Configuration rejected");
            break :rejected .rejected;
        },
        .adopted => |adoption| .{ .adopted = try apply(client, adoption) },
    };
    try schedule(client);

    return outcome;
}

fn commitDiagnostic(client: *Client, diagnostic: lua_config.Diagnostic) !void {
    _ = try client_diagnostics.replace(client, .{
        .diagnostic = diagnostic,
        .invalid_fallback = client_diagnostics.formatted(
            "configuration reload failed: invalid diagnostic text",
            .{},
        ),
    });
}

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
            .project_appearance = projectAppearance,
            .configure_sidebar = configureSidebar,
            .apply_sidebar = applySidebar,
            .sync_pane_layout = syncPaneLayout,
            .publish_success = publishSuccess,
        },
    };
    const snapshot = &adoption.generation.snapshot;
    const commit = try use_case.execute(.{
        .configuration = .{
            .generation = adoption.generation.number,
            .sidebar_visible = snapshot.sidebar_visible,
            .pane_gaps = snapshot.pane_gaps,
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
        context.client.view.setTheme(snapshot.theme);
    }
    context.client.view.setIconTheme(snapshot.icon_theme);
}

fn configureSidebar(raw_context: *anyopaque) !void {
    const context: *AdoptionContext = @ptrCast(@alignCast(raw_context));
    const client = context.client;
    const host_size = client.model.hostSize();

    try client.view.configureSidebar(
        client.sidebar_rendering,
        client.model.hostCapabilities().kitty_graphics,
        host_size.cell_width_px,
        host_size.cell_height_px,
    );
}

fn applySidebar(raw_context: *anyopaque, change: client_model.SidebarVisibility) !void {
    const context: *AdoptionContext = @ptrCast(@alignCast(raw_context));
    try sidebar_projection.apply(context.client, change);
}

fn syncPaneLayout(raw_context: *anyopaque) !void {
    const context: *AdoptionContext = @ptrCast(@alignCast(raw_context));
    const client = context.client;
    client.graphics_store.invalidatePlacements();
    if (client.model.workspace.active()) |active| {
        try pane_geometry.offerAttached(client, &active.model, client.view.workbench());
    }
}

fn publishSuccess(raw_context: *anyopaque) !void {
    const context: *AdoptionContext = @ptrCast(@alignCast(raw_context));
    try notification_flow.publishNow(context.client, .{
        .level = .success,
        .title = "Configuration reloaded",
        .message = "The new settings are active",
    });
}
