//! Wires committed pane viewports to graphics and the runtime attachment.

const core = @import("telar-core");
const panes_application = @import("application/panes/root.zig");
const client_model = @import("model.zig");

const Client = @import("client.zig");
const runtime_transport = @import("runtime_transport.zig");
const pane_viewport_delivery = panes_application.pane_viewport_delivery;
const set_pane_viewport = panes_application.set_pane_viewport;
const schema = core.schema;

pub const Target = client_model.PaneViewportTarget;

/// Wires viewport intent to the shared graphics and runtime effect.
///
/// ```zig
/// var use_case = handler(client);
/// _ = try use_case.execute(.{ .pane_id = pane_id, .target = .bottom });
/// ```
pub fn handler(client: *Client) set_pane_viewport.SetPaneViewportHandler {
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
pub fn effects(client: *Client) set_pane_viewport.PaneViewportEffects {
    return .{
        .context = client,
        .sync = sync,
    };
}

fn sync(context: *anyopaque, change: client_model.PaneViewportChange) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const delivery_handler: pane_viewport_delivery.DeliverPaneViewportHandler = .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .set_graphics_visible = setGraphicsVisible,
            .deliver_viewport = deliverViewport,
        },
    };

    try delivery_handler.execute(change);
}

fn setGraphicsVisible(context: *anyopaque, pane_id: schema.PaneId, visible: bool) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try client.graphics_store.setPaneVisible(pane_id, visible);
}

fn deliverViewport(context: *anyopaque, viewport: schema.SetPaneViewport) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try runtime_transport.enqueue(client, .{ .set_pane_viewport = viewport });
}
