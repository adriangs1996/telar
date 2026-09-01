//! Adapts pane-geometry application commands to graphics and runtime ports.

const core = @import("telar-core");
const workspace_capability = @import("../../../workspace/root.zig");
const panes_application = @import("../../application/panes/root.zig");
const client_model = @import("../../model.zig");
const runtime_transport = @import("../../runtime_transport.zig");

const Client = @import("../../client.zig");
const pane_geometry_delivery = panes_application.pane_geometry_delivery;
const resize_pane = panes_application.resize_pane;
const multiplexer = workspace_capability.multiplexer;
const toggle_pane_fullscreen = panes_application.toggle_pane_fullscreen;
const ui = core.ui;

/// Offers the current visible size of every attached pane to the runtime.
///
/// ```zig
/// try offerAttached(client, model, client.view.workbench());
/// ```
pub fn offerAttached(client: *Client, model: *multiplexer.Model, area: ui.Rect) !void {
    var use_case: pane_geometry_delivery.OfferPaneGeometryHandler = .{
        .effects = offerEffects(client),
    };

    _ = try use_case.execute(model, area);
}

/// Selects the active tab and offers its attached visible pane geometry.
///
/// ```zig
/// try offerActive(client, client.view.workbench());
/// ```
pub fn offerActive(client: *Client, area: ui.Rect) !void {
    var use_case: pane_geometry_delivery.OfferActivePaneGeometryHandler = .{
        .model = &client.model,
        .effects = offerEffects(client),
    };

    _ = try use_case.execute(area);
}

/// Returns the runtime resize port reused by compound geometry deliveries.
///
/// ```zig
/// const effects = offerEffects(client);
/// ```
pub fn offerEffects(client: *Client) pane_geometry_delivery.OfferEffects {
    return .{
        .context = client,
        .deliver_resize = deliverResize,
    };
}

/// Wires pane edge resizing to the shared geometry effect.
///
/// ```zig
/// var use_case = resizeHandler(client);
/// _ = try use_case.execute(.{ .direction = .right, .area = area });
/// ```
pub fn resizeHandler(client: *Client) resize_pane.ResizePaneHandler {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .deliver = deliverGeometry,
        },
    };
}

/// Wires fullscreen toggling to the shared geometry effect.
///
/// ```zig
/// var use_case = fullscreenHandler(client);
/// _ = try use_case.execute(.{ .area = area });
/// ```
pub fn fullscreenHandler(client: *Client) toggle_pane_fullscreen.TogglePaneFullscreenHandler {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .deliver = deliverGeometry,
        },
    };
}

fn deliverGeometry(context: *anyopaque, change: client_model.PaneGeometryChange) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    var use_case: pane_geometry_delivery.DeliverPaneGeometryHandler = .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .invalidate_graphics_placements = invalidateGraphicsPlacements,
            .deliver_resize = deliverResize,
        },
    };

    _ = try use_case.execute(change);
}

fn invalidateGraphicsPlacements(raw_context: *anyopaque) void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    client.graphics_store.invalidatePlacements();
}

fn deliverResize(raw_context: *anyopaque, resize: core.schema.PaneResize) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    try runtime_transport.enqueue(client, .{ .pane_resize = resize });
}
