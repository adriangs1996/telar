//! Adapts pane-graphics reconciliation to the physical Kitty store and IPC.

const Client = @import("../../Client.zig");
const ApplicationPanesPaneGraphicsCommand = @import("telar-client").ApplicationPanesPaneGraphicsCommand;
const ApplicationPanesPaneGraphicsOutcome = @import("telar-client").ApplicationPanesPaneGraphicsOutcome;
const enabled_module = @import("telar-core").enabled;
const SyncPaneGraphicsFallbacksHandlerType = @import("telar-client").SyncPaneGraphicsFallbacksHandler;
const ReconcilePaneGraphicsHandlerType = @import("telar-client").ReconcilePaneGraphicsHandler;
const PaneIdType = @import("telar-core").PaneId;
const ResourceResultType = @import("telar-client").ResourceResult;
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

    return client.graphics_store.hasPaneGraphics(pane_id);
}

fn applyResources(context: *anyopaque, command: ApplicationPanesPaneGraphicsCommand) !ResourceResultType {
    const client: *Client = @ptrCast(@alignCast(context));
    const before = client.graphics_store.ingressVersion();
    const applied = switch (command) {
        .snapshot => |message| client.graphics_store.applySnapshot(message),
        .image => |message| client.graphics_store.applyImage(message),
        .shared_image => |message| client.graphics_store.applySharedImage(message),
        .image_chunk => |message| client.graphics_store.applyChunk(message),
        .placement => |message| client.graphics_store.applyPlacement(message),
        .delete_image => |message| client.graphics_store.deleteImage(message),
        .delete_placement => |message| client.graphics_store.deletePlacement(message),
    };
    applied catch |err| switch (err) {
        error.GraphicsResyncRequired => return .{ .resync_required = command.paneId() },
        error.GraphicsSharedMappingFailed => return .{ .shared_mapping_failed = command.paneId() },
        else => return err,
    };

    if (client.graphics_store.ingressVersion() == before) {
        return .unchanged;
    }

    const pane_id = command.paneId();
    return .{ .changed = .{
        .pane_id = pane_id,
        .has_graphics = client.graphics_store.hasPaneGraphics(pane_id),
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
