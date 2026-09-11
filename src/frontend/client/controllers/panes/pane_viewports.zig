//! Wires committed pane viewports to graphics and the runtime attachment.

const Client = @import("../../Client.zig");
const SetPaneViewportHandlerType = @import("telar-client").SetPaneViewportHandler;
const PaneViewportEffectsType = @import("telar-client").PaneViewportEffects;
const PaneViewportChangeType = @import("telar-client").PaneViewportChange;
const DeliverPaneViewportHandlerType = @import("telar-client").DeliverPaneViewportHandler;
const PaneIdType = @import("telar-core").PaneId;
const SetPaneViewportType = @import("telar-core").SetPaneViewport;
const runtime_transport = @import("../../entrypoints/runtime_io.zig");

/// Wires viewport intent to the shared graphics and runtime effect.
///
/// ```zig
/// var use_case = handler(client);
/// _ = try use_case.execute(.{ .pane_id = pane_id, .target = .bottom });
/// ```
pub fn handler(client: *Client) SetPaneViewportHandlerType {
    return .{
        .model = &client.model,
        .effects = effects(client),
    };
}

/// Returns the viewport delivery port reused by compound client transactions.
///
/// ```zig
/// const viewport_effects = effects(client);
/// ```
pub fn effects(client: *Client) PaneViewportEffectsType {
    return .{
        .context = client,
        .sync = sync,
    };
}

fn sync(context: *anyopaque, change: PaneViewportChangeType) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const delivery_handler: DeliverPaneViewportHandlerType = .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .set_graphics_visible = setGraphicsVisible,
            .deliver_viewport = deliverViewport,
        },
    };

    try delivery_handler.execute(change);
}

fn setGraphicsVisible(context: *anyopaque, pane_id: PaneIdType, visible: bool) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try client.graphics_store.setPaneVisible(pane_id, visible);
}

fn deliverViewport(context: *anyopaque, viewport: SetPaneViewportType) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try runtime_transport.enqueue(client, .{ .set_pane_viewport = viewport });
}
