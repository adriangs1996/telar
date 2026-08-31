//! Adapts pane-graphics reconciliation to the physical Kitty store and IPC.

const core = @import("telar-core");
const client_application = @import("application/root.zig");

const Client = @import("client.zig");
const diagnostics = core.diagnostics;
const pane_graphics = client_application.pane_graphics;
const runtime_transport = @import("runtime_transport.zig");
const schema = core.schema;

/// Reconciles one decoded runtime graphics command through the application
/// boundary. Presentation observes model and store revisions afterwards.
///
/// ```zig
/// _ = try apply(client, command);
/// ```
pub fn apply(client: *Client, command: pane_graphics.Command) !pane_graphics.Outcome {
    if (comptime diagnostics.enabled) {
        switch (command) {
            .image, .shared_image => client.telemetry.metrics.graphics_images += 1,
            else => {},
        }
    }

    var use_case = handler(client);
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
    const fallback_required = client.model.hostCapabilities().kitty_graphics != .supported;
    var tabs = client.model.workspace.tabIterator();
    while (tabs.next()) |tab| {
        var panes = tab.model.paneIterator();
        while (panes.next()) |pane| {
            _ = client.model.setPaneGraphicsFallback(
                pane.id,
                fallback_required and client.graphics_store.hasPaneGraphics(pane.id),
            );
        }
    }
}

fn handler(client: *Client) pane_graphics.ReconcilePaneGraphicsHandler {
    return .{
        .model = &client.model,
        .fallback_required = client.model.hostCapabilities().kitty_graphics != .supported,
        .effects = .{
            .context = client,
            .apply = applyResources,
            .request_snapshot = requestSnapshot,
            .disable_shared = disableShared,
        },
    };
}

fn applyResources(context: *anyopaque, command: pane_graphics.Command) !pane_graphics.ResourceResult {
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

fn requestSnapshot(context: *anyopaque, pane_id: schema.PaneId) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try runtime_transport.enqueue(client, .{ .request_graphics_snapshot = .{ .pane_id = pane_id } });
}

fn disableShared(context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try runtime_transport.enqueue(client, .{ .configure_graphics = .{ .shared = false } });
}
