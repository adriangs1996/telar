//! Projects committed sidebar visibility into disposable client resources.

const Client = @import("../../AttachedClient.zig");
const SidebarLayoutType = @import("../../model/SidebarLayout.zig");
const DeliverSidebarLayoutHandlerType = @import("../../application/notifications/DeliverSidebarLayoutHandler.zig");
const MultiplexerModel = @import("../../workspace/MultiplexerModel.zig");
const pane_geometry = @import("../panes/pane_geometry.zig");

/// Applies one exact model commit to the view, physical graphics placements
/// and attached runtime pane geometry.
///
/// ```zig
/// try apply(client, change);
/// ```
pub fn apply(client: *Client, change: SidebarLayoutType) !void {
    const delivery_handler: DeliverSidebarLayoutHandlerType = .{
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

    client.chrome.setSidebarLayout(visible, width);
}

fn invalidateGraphicsPlacements(context: *anyopaque) void {
    const client: *Client = @ptrCast(@alignCast(context));

    client.host_graphics.invalidatePlacements();
}

fn offerPaneGeometry(context: *anyopaque, model: *MultiplexerModel) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try pane_geometry.offerAttached(client, model, client.geometry().area);
}
