//! Adapts pane-geometry application commands to graphics and runtime ports.

const Client = @import("../../Client.zig");
const MultiplexerModel = @import("telar-client").MultiplexerModel;
const RectType = @import("telar-core").Rect;
const OfferPaneGeometryHandlerType = @import("telar-client").OfferPaneGeometryHandler;
const OfferActivePaneGeometryHandlerType = @import("telar-client").OfferActivePaneGeometryHandler;
const OfferEffectsType = @import("telar-client").OfferEffects;
const ResizePaneHandlerType = @import("telar-client").ResizePaneHandler;
const TogglePaneFullscreenHandlerType = @import("telar-client").TogglePaneFullscreenHandler;
const PaneGeometryChangeType = @import("telar-client").PaneGeometryChange;
const DeliverPaneGeometryHandlerType = @import("telar-client").DeliverPaneGeometryHandler;
const tab_snapshots = @import("../tabs/tab_snapshots.zig");
const kitty_delivery = @import("../../../graphics/kitty_delivery.zig");
const PaneResizeType = @import("telar-core").PaneResize;
const runtime_transport = @import("../../entrypoints/runtime_io.zig");
const PaneBottomReservationType = @import("telar-client").PaneBottomReservation;

/// Offers the current visible size of every attached pane to the runtime.
///
/// ```zig
/// try offerAttached(client, model, client.geometry().area);
/// ```
pub fn offerAttached(client: *Client, model: *MultiplexerModel, area: RectType) !void {
    var use_case: OfferPaneGeometryHandlerType = .{
        .effects = offerEffects(client),
    };

    _ = try use_case.execute(model, area);
}

/// Selects the active tab and offers its attached visible pane geometry.
///
/// ```zig
/// try offerActive(client, client.geometry().area);
/// ```
pub fn offerActive(client: *Client, area: RectType) !void {
    var use_case: OfferActivePaneGeometryHandlerType = .{
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
pub fn offerEffects(client: *Client) OfferEffectsType {
    return .{
        .context = client,
        .deliver_resize = deliverResize,
        .bottom_reservation = bottomReservation,
    };
}

/// Wires pane edge resizing to the shared geometry effect.
///
/// ```zig
/// var use_case = resizeHandler(client);
/// _ = try use_case.execute(.{ .direction = .right, .area = area });
/// ```
pub fn resizeHandler(client: *Client) ResizePaneHandlerType {
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
pub fn fullscreenHandler(client: *Client) TogglePaneFullscreenHandlerType {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .deliver = deliverGeometry,
        },
    };
}

fn deliverGeometry(context: *anyopaque, change: PaneGeometryChangeType) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    var use_case: DeliverPaneGeometryHandlerType = .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .invalidate_graphics_placements = invalidateGraphicsPlacements,
            .request_visible_attachments = requestVisibleAttachments,
            .deliver_resize = deliverResize,
            .bottom_reservation = bottomReservation,
        },
    };

    _ = try use_case.execute(change);
}

fn requestVisibleAttachments(raw_context: *anyopaque, area: RectType) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    try tab_snapshots.attachActive(client, area);
}

fn invalidateGraphicsPlacements(raw_context: *anyopaque) void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    kitty_delivery.invalidatePlacements(&client.graphics_store);
}

fn deliverResize(raw_context: *anyopaque, resize: PaneResizeType) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    try runtime_transport.enqueue(client, .{ .pane_resize = resize });
}

fn bottomReservation(raw_context: *anyopaque) ?PaneBottomReservationType {
    const client: *Client = @ptrCast(@alignCast(raw_context));

    return client.view.attachmentReservation();
}
