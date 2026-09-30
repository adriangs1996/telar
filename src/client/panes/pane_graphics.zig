//! Reconciles retained resources and semantic fallbacks using concrete dependencies.

const data = @import("model");
const GraphicsRetention = @import("../graphics/GraphicsRetention.zig");

const std = @import("std");
const core = @import("telar-core");
const Client = @import("../execution/Client.zig");

/// Reconciles all fallbacks when host support changes. Example: `syncFallbacks(model, graphics);`
pub fn syncFallbacks(model: *data.ClientModel, graphics: GraphicsRetention) void {
    const fallback_required = model.host.host_capabilities.images != .supported;
    var inspected: usize = 0;
    var panes = model.panes.iterate(null);
    while (panes.next()) |pane| {
        inspected += 1;
        const has_graphics = fallback_required and
            graphics.hasPaneGraphics(pane.id);
        _ = data.pane_graphics.setFallback(model, pane.id, has_graphics);
    }

    std.debug.assert(inspected <= core.max_tabs_per_workspace * core.max_panes_per_tab);
}

/// Classifies bounded ingress recovery without sending runtime messages.
/// Example: `const result = try applyResources(graphics, command);`
pub fn applyResources(graphics: GraphicsRetention, command: data.PaneGraphicsCommand) !data.PaneGraphicsResourceResult {
    const before = graphics.ingressVersion();
    graphics.apply(command) catch |err| switch (err) {
        error.GraphicsResyncRequired => return .{ .resync_required = command.paneId() },
        error.GraphicsSharedMappingFailed => return .{ .shared_mapping_failed = command.paneId() },
        else => return err,
    };

    if (graphics.ingressVersion() == before) {
        return .unchanged;
    }

    const pane_id = command.paneId();
    return .{ .changed = .{
        .pane_id = pane_id,
        .has_graphics = graphics.hasPaneGraphics(pane_id),
    } };
}

/// Reconciles physical graphics and semantic fallback, recovering bounded ingress failures.
pub fn applyPaneGraphics(client: *Client, command: data.PaneGraphicsCommand) !PaneGraphicsOutcome {
    if (comptime core.enabled) {
        switch (command) {
            .image, .shared_image => client.telemetry.metrics.graphics_images += 1,
            else => {},
        }
    }

    const pane_id = command.paneId();
    const resource = try applyResources(client.graphics, command);

    return switch (resource) {
        .unchanged => .unchanged,
        .changed => |state| block: {
            if (state.pane_id != pane_id) {
                return error.InvalidPaneGraphicsResult;
            }

            break :block .{
                .applied = .{
                    .pane_id = pane_id,
                    .fallback = data.pane_graphics.setFallback(&client.model, 
                        pane_id,
                        client.model.host.host_capabilities.images != .supported and
                            state.has_graphics,
                    ),
                },
            };
        },
        .resync_required => |recovery_pane| block: {
            if (recovery_pane != pane_id) {
                return error.InvalidPaneGraphicsResult;
            }

            if (comptime core.enabled) {
                client.telemetry.metrics.graphics_resyncs += 1;
            }

            try client.model.to_runtime.push(
                .{
                    .request_graphics_snapshot = .{
                        .pane_id = pane_id,
                    },
                },
            );
            break :block .{
                .resync_requested = pane_id,
            };
        },
        .shared_mapping_failed => |recovery_pane| block: {
            if (recovery_pane != pane_id) {
                return error.InvalidPaneGraphicsResult;
            }

            try client.model.to_runtime.push(
                .{
                    .configure_graphics = .{
                        .shared = false,
                    },
                },
            );
            try client.model.to_runtime.push(
                .{
                    .request_graphics_snapshot = .{
                        .pane_id = pane_id,
                    },
                },
            );
            break :block .{
                .shared_disabled = pane_id,
            };
        },
    };
}

const PaneGraphicsApplied = struct {
    pane_id: core.PaneId,
    fallback: ?data.PaneGraphicsFallbackCommit,
};

const PaneGraphicsOutcome = union(enum) {
    unchanged,
    applied: PaneGraphicsApplied,
    resync_requested: core.PaneId,
    shared_disabled: core.PaneId,
};
