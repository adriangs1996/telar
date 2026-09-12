//! Adapts pane-graphics reconciliation to the physical Kitty store and IPC.

const Client = @import("../../AttachedClient.zig");
const ApplicationPanesPaneGraphicsCommand = @import("../../application/panes/pane_graphics.zig").Command;
const ApplicationPanesPaneGraphicsOutcome = @import("../../application/panes/pane_graphics.zig").Outcome;
const enabled_module = @import("telar-core").enabled;
const SyncPaneGraphicsFallbacksHandlerType = @import("../../application/panes/SyncPaneGraphicsFallbacksHandler.zig");
const ReconcilePaneGraphicsHandlerType = @import("../../application/panes/ReconcilePaneGraphicsHandler.zig");
const PaneIdType = @import("telar-core").PaneId;
const ResourceResultType = @import("../../application/panes/pane_graphics.zig").ResourceResult;
const runtime_transport = @import("../../entrypoints/runtime_io.zig");

/// Reconciles one decoded runtime graphics command through the application
/// boundary. Presentation observes model and store revisions afterwards.
///
/// ```zig
/// _ = try apply(client, command);
/// ```
pub fn apply(client: *Client, command: ApplicationPanesPaneGraphicsCommand) !ApplicationPanesPaneGraphicsOutcome {
    if (comptime enabled_module) {
        switch (command) {
            .image, .shared_image => client.telemetry.metrics.graphics_images += 1,
            else => {},
        }
    }

    var use_case = reconciliationHandler(client);
    return use_case.execute(command);
}

/// Reconciles every pane fallback after host graphics capability changes.
/// Physical resources remain in the Kitty store; only the derived cell flag
/// enters the client model.
///
/// ```zig
/// syncFallbacks(client);
/// ```
pub fn syncFallbacks(client: *Client) void {
    var use_case: SyncPaneGraphicsFallbacksHandlerType = .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .has_graphics = hasGraphics,
        },
    };

    use_case.execute();
}

fn reconciliationHandler(client: *Client) ReconcilePaneGraphicsHandlerType {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .apply = applyResources,
            .request_snapshot = requestSnapshot,
            .disable_shared = disableShared,
        },
    };
}

fn hasGraphics(context: *anyopaque, pane_id: PaneIdType) bool {
    const client: *Client = @ptrCast(@alignCast(context));

    return client.graphics.hasPaneGraphics(pane_id);
}

fn applyResources(context: *anyopaque, command: ApplicationPanesPaneGraphicsCommand) !ResourceResultType {
    const client: *Client = @ptrCast(@alignCast(context));
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

fn requestSnapshot(context: *anyopaque, pane_id: PaneIdType) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try runtime_transport.enqueue(client, .{ .request_graphics_snapshot = .{ .pane_id = pane_id } });
}

fn disableShared(context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try runtime_transport.enqueue(client, .{ .configure_graphics = .{ .shared = false } });
}
