//! Projects committed sidebar visibility into disposable client resources.

const Client = @import("../../Client.zig");
const SidebarLayoutType = @import("telar-client").SidebarLayout;
const DeliverSidebarLayoutHandlerType = @import("telar-client").DeliverSidebarLayoutHandler;
const kitty_delivery = @import("../../../graphics/kitty_delivery.zig");
const MultiplexerModel = @import("telar-client").MultiplexerModel;
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

    client.view.setSidebarLayout(visible, width);
}

fn invalidateGraphicsPlacements(context: *anyopaque) void {
    const client: *Client = @ptrCast(@alignCast(context));

    kitty_delivery.invalidatePlacements(&client.graphics_store);
}

fn offerPaneGeometry(context: *anyopaque, model: *MultiplexerModel) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try pane_geometry.offerAttached(client, model, client.geometry().area);
}
