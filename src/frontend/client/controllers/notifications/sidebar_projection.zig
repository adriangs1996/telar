//! Projects committed sidebar visibility into disposable client resources.

const workspace_capability = @import("../../../workspace/root.zig");
const notifications_application = @import("../../application/notifications/root.zig");
const client_model = @import("../../model/root.zig");
const pane_geometry = @import("../panes/pane_geometry.zig");

const Client = @import("../../client.zig");
const multiplexer = workspace_capability.multiplexer;
const sidebar_layout_delivery = notifications_application.sidebar_layout_delivery;

/// Applies one exact model commit to the view, physical graphics placements
/// and attached runtime pane geometry.
///
/// ```zig
/// try apply(client, change);
/// ```
pub fn apply(client: *Client, change: client_model.SidebarLayout) !void {
    const delivery_handler: sidebar_layout_delivery.DeliverSidebarLayoutHandler = .{
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

fn projectView(context: *anyopaque, visible: bool, width: u16) void {
    const client: *Client = @ptrCast(@alignCast(context));

    client.view.setSidebarLayout(visible, width);
}

fn invalidateGraphicsPlacements(context: *anyopaque) void {
    const client: *Client = @ptrCast(@alignCast(context));

    client.graphics_store.invalidatePlacements();
}

fn offerPaneGeometry(context: *anyopaque, model: *multiplexer.Model) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try pane_geometry.offerAttached(client, model, client.view.workbench());
}
