//! Projects committed sidebar visibility into disposable client resources.

const workspace_capability = @import("../workspace/root.zig");
const notifications_application = @import("application/notifications/root.zig");
const client_model = @import("model.zig");
const pane_geometry = @import("pane_geometry.zig");

const Client = @import("client.zig");
const multiplexer = workspace_capability.multiplexer;
const sidebar_visibility_delivery = notifications_application.sidebar_visibility_delivery;

/// Applies one exact model commit to the view, physical graphics placements
/// and attached runtime pane geometry.
///
/// ```zig
/// try apply(client, change);
/// ```
pub fn apply(client: *Client, change: client_model.SidebarVisibility) !void {
    const delivery_handler: sidebar_visibility_delivery.DeliverSidebarVisibilityHandler = .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .project_view = projectView,
            .invalidate_graphics_placements = invalidateGraphicsPlacements,
            .offer_pane_geometry = offerPaneGeometry,
        },
    };

    try delivery_handler.execute(change);
}

fn projectView(context: *anyopaque, visible: bool) void {
    const client: *Client = @ptrCast(@alignCast(context));

    client.view.setSidebarVisible(visible);
}

fn invalidateGraphicsPlacements(context: *anyopaque) void {
    const client: *Client = @ptrCast(@alignCast(context));

    client.graphics_store.invalidatePlacements();
}

fn offerPaneGeometry(context: *anyopaque, model: *multiplexer.Model) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try pane_geometry.offerAttached(client, model, client.view.workbench());
}
