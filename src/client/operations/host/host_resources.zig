//! Commits host changes and synchronizes the client's resources in order.
//! Host ports are the only dynamic boundary; shared policy calls them directly.

const std = @import("std");
const Client = @import("../../AttachedClient.zig");
const Model = @import("../../model/Model.zig");
const HostCommit = @import("../../model/HostCommit.zig");
const HostUpdate = @import("../../model/HostUpdate.zig");
const HostCapabilities = @import("../../model/HostCapabilities.zig");
const types = @import("../../model/types.zig");
const runtime_io = @import("../../entrypoints/runtime_io.zig");
const pane_graphics = @import("../panes/pane_graphics.zig");
const pane_geometry = @import("../panes/pane_geometry.zig");
const tab_snapshots = @import("../tabs/tab_snapshots.zig");

/// Commits validated geometry before touching resources. Delivery failure keeps
/// the committed state; the caller ends the client session.
/// Example: `_ = try apply(client, .{ .size = size, .capabilities = capabilities });`
pub fn apply(client: *Client, update: HostUpdate) !?HostCommit {
    const commit = try client.model.reconcileHost(update) orelse return null;

    try deliver(client, commit);
    return commit;
}

/// Applies a semantic terminal response through the same resource policy.
/// Example: `_ = try observe(client, .{ .images = .supported });`
pub fn observe(client: *Client, observation: types.HostCapabilityObservation) !?HostCommit {
    const commit = try client.model.observeHostCapability(observation) orelse return null;

    try deliver(client, commit);
    return commit;
}

/// Resolves geometry when a probe settles a complete set of capabilities.
/// Example: `_ = try reconcile(client, capabilities);`
pub fn reconcile(client: *Client, capabilities: HostCapabilities) !?HostCommit {
    var size = client.model.hostSize();
    const cell_size = capabilities.cellSize(size.cols, size.rows);
    size.cell_width_px = cell_size.width;
    size.cell_height_px = cell_size.height;

    return apply(client, .{ .size = size, .capabilities = capabilities });
}

/// Delivers a current commit, stopping at the first failed resource operation.
/// Example: `try deliver(client, commit);`
pub fn deliver(client: *Client, commit: HostCommit) !void {
    try validate(&client.model, commit);

    if (commit.capabilities) |change| {
        if (!std.meta.eql(change.previous.terminal_colors, change.current.terminal_colors) and
            (client.startup.phase == .opening or client.startup.phase == .active))
        {
            try runtime_io.enqueue(client, .{ .configure_terminal_colors = change.current.terminal_colors });
        }

        if (change.previous.appearance != change.current.appearance and !client.options.theme_locked) {
            const theme = switch (change.current.appearance) {
                .unknown => null,
                .light => client.appearance_themes.light,
                .dark => client.appearance_themes.dark,
            };
            if (theme) |value| {
                client.chrome.setTheme(value);
            }
        }

        if (change.previous.images != change.current.images) {
            pane_graphics.syncFallbacks(client);
            const size = client.model.hostSize();
            try client.chrome.configureSidebar(.{
                .support = change.current.images,
                .cell_width = size.cell_width_px,
                .cell_height = size.cell_height_px,
            });
            client.host_graphics.invalidatePlacements();
        }
    }

    if (commit.resize) |resize| {
        if (resize.grid_changed) {
            try client.presentation.resize(resize.current.cols, resize.current.rows);
            try client.chrome.resize(resize.current.cols, resize.current.rows);
        }

        if (resize.cell_size_changed) {
            try client.chrome.configureSidebar(.{
                .support = client.model.hostCapabilities().images,
                .cell_width = resize.current.cell_width_px,
                .cell_height = resize.current.cell_height_px,
            });
        }

        client.host_graphics.invalidatePlacements();
        try pane_geometry.offerActive(client, client.geometry().area);
        try tab_snapshots.attachActive(client, client.geometry().area);
    }
}

fn validate(model: *const Model, commit: HostCommit) !void {
    if (commit.capabilities == null and commit.resize == null) {
        return error.EmptyHostCommit;
    }

    const version = model.version();
    if (commit.capabilities) |change| {
        if (!std.meta.eql(model.hostCapabilities(), change.current) or
            version.host_capabilities != change.host_capabilities_revision)
        {
            return error.StaleHostCommit;
        }
    }

    if (commit.resize) |resize| {
        if (!std.meta.eql(model.hostSize(), resize.current) or version.host != resize.host_revision) {
            return error.StaleHostCommit;
        }
    }
}
