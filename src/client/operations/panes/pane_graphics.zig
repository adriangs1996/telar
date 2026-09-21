//! Adapts pane-graphics reconciliation to the physical Kitty store and IPC.

const Client = @import("../../AttachedClient.zig");
const ApplicationPanesPaneGraphicsCommand = @import("../../application/panes/pane_graphics.zig").Command;
const ApplicationPanesPaneGraphicsOutcome = @import("../../application/panes/pane_graphics.zig").Outcome;
const enabled_module = @import("telar-core").enabled;
const ResourceResultType = @import("../../application/panes/pane_graphics.zig").ResourceResult;
const runtime_transport = @import("../../entrypoints/runtime_io.zig");

const std = @import("std");
const core = @import("telar-core");

/// Reconciles physical graphics and semantic fallback, recovering bounded ingress failures. Example: `_ = try apply(client, command);`
pub fn apply(client: *Client, command: ApplicationPanesPaneGraphicsCommand) !ApplicationPanesPaneGraphicsOutcome {
    if (comptime enabled_module) {
        switch (command) {
            .image, .shared_image => client.telemetry.metrics.graphics_images += 1,
            else => {},
        }
    }

    const pane_id = command.paneId();
    const resource = try applyResources(client, command);

    return switch (resource) {
        .unchanged => .unchanged,
        .changed => |state| block: {
            if (state.pane_id != pane_id) {
                return error.InvalidPaneGraphicsResult;
            }

            break :block .{ .applied = .{
                .pane_id = pane_id,
                .fallback = client.model.setPaneGraphicsFallback(
                    pane_id,
                    client.model.hostCapabilities().images != .supported and
                        state.has_graphics,
                ),
            } };
        },
        .resync_required => |recovery_pane| block: {
            if (recovery_pane != pane_id) {
                return error.InvalidPaneGraphicsResult;
            }

            try runtime_transport.enqueue(client, .{ .request_graphics_snapshot = .{ .pane_id = pane_id } });
            break :block .{ .resync_requested = pane_id };
        },
        .shared_mapping_failed => |recovery_pane| block: {
            if (recovery_pane != pane_id) {
                return error.InvalidPaneGraphicsResult;
            }

            try runtime_transport.enqueue(client, .{ .configure_graphics = .{ .shared = false } });
            try runtime_transport.enqueue(client, .{ .request_graphics_snapshot = .{ .pane_id = pane_id } });
            break :block .{ .shared_disabled = pane_id };
        },
    };
}

/// Reconciles all fallbacks when host support changes. Example: `syncFallbacks(client);`
pub fn syncFallbacks(client: *Client) void {
    const fallback_required = client.model.hostCapabilities().images != .supported;
    var inspected: usize = 0;
    var tabs = client.model.workspace.tabIterator();
    while (tabs.next()) |tab| {
        var panes = tab.model.paneIterator();
        while (panes.next()) |pane| {
            inspected += 1;
            const has_graphics = fallback_required and
                client.graphics.hasPaneGraphics(pane.id);
            _ = client.model.setPaneGraphicsFallback(pane.id, has_graphics);
        }
    }

    std.debug.assert(inspected <= core.max_tabs_per_workspace * core.max_panes_per_tab);
}

fn applyResources(client: *Client, command: ApplicationPanesPaneGraphicsCommand) !ResourceResultType {
    const before = client.graphics.ingressVersion();
    client.graphics.apply(command) catch |err| switch (err) {
        error.GraphicsResyncRequired => return .{ .resync_required = command.paneId() },
        error.GraphicsSharedMappingFailed => return .{ .shared_mapping_failed = command.paneId() },
        else => return err,
    };

    if (client.graphics.ingressVersion() == before) {
        return .unchanged;
    }

    const pane_id = command.paneId();
    return .{ .changed = .{
        .pane_id = pane_id,
        .has_graphics = client.graphics.hasPaneGraphics(pane_id),
    } };
}
