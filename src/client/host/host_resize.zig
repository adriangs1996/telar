//! Host resize: commits a new host size and capabilities, then resizes and
//! reattaches what the new geometry shows.
const data = @import("model");
const std = @import("std");
const pane_graphics = @import("../panes/pane_graphics.zig");
const client_tests = @import("../execution/client_tests.zig");
const pane_attachment = @import("../panes/pane_attachment.zig");
const pane_resize = @import("../panes/pane_resize.zig");
const Client = @import("../execution/Client.zig");

/// Commits validated geometry before touching resources. Delivery failure keeps
/// the committed state; the caller ends the client session.
/// Example: `_ = try host_resize.applyHostUpdate(client, host_update);`
pub fn applyHostUpdate(client: *Client, host_update: data.HostUpdate) !?data.HostCommit {
    const commit = try data.host_capabilities.reconcile(&client.model, host_update) orelse return null;

    try deliverHostCommit(client, commit);

    return commit;
}

/// Delivers a current commit, stopping at the first failed resource operation.
pub fn deliverHostCommit(client: *Client, commit: data.HostCommit) !void {
    try validateHostCommit(&client.model, commit);

    if (commit.capabilities) |change| {
        if (!std.meta.eql(change.previous.terminal_colors, change.current.terminal_colors) and
            (client.model.startup.phase == .opening or client.model.startup.phase == .active))
        {
            try client.model.to_runtime.push(
                .{
                    .configure_terminal_colors = change.current.terminal_colors,
                },
            );
        }

        if (change.previous.frame_interval_ns != change.current.frame_interval_ns and
            (client.model.startup.phase == .opening or client.model.startup.phase == .active))
        {
            try client.model.to_runtime.push(
                .{
                    .configure_frame_interval = .{
                        .interval_ns = change.current.frame_interval_ns,
                    },
                },
            );
        }

        if (change.previous.appearance != change.current.appearance and !client.options.theme_locked) {
            const theme = switch (change.current.appearance) {
                .unknown => null,
                .light => client.model.config.themes.light,
                .dark => client.model.config.themes.dark,
            };

            if (theme) |value| {
                client.model.theme = value;
            }
        }

        if (change.previous.images != change.current.images) {
            pane_graphics.syncFallbacks(&client.model, client.graphics);
            client.model.to_host.invalidate_placements = true;
        }
    }

    if (commit.resize) |_| {
        client.model.to_host.invalidate_placements = true;
        if (client.model.tabs.activeSlot()) |tab| {
            const area = client.geometry().area;
            try pane_resize.resizeAttachedPanes(client, tab, area);

            if (client.model.tabs.snapshot_loaded[tab]) {
                try pane_attachment.attachVisiblePanes(&client.model, tab, area);
            }
        }
    }
}

fn validateHostCommit(model: *const data.ClientModel, commit: data.HostCommit) !void {
    if (commit.capabilities == null and commit.resize == null) {
        return error.EmptyHostCommit;
    }

    const version = model.version();

    if (commit.capabilities) |change| {
        if (!std.meta.eql(model.host.host_capabilities, change.current) or
            version.host_capabilities != change.host_capabilities_revision)
        {
            return error.StaleHostCommit;
        }
    }

    if (commit.resize) |resize| {
        if (!std.meta.eql(model.host.host_size, resize.current) or version.host != resize.host_revision) {
            return error.StaleHostCommit;
        }
    }
}

test "host resources reject empty and stale commits before calling ports" {
    try client_tests.rejectStaleHostCommits(deliverHostCommit);
}
