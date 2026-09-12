//! Wires pane closure and exit use cases to one disposable client.

const Client = @import("../../AttachedClient.zig");
const RequestClosePaneHandlerType = @import("../../application/panes/RequestClosePaneHandler.zig");
const PaneExitedType = @import("telar-core").PaneExited;
const PaneExitType = @import("../../model/types.zig").PaneExit;
const HandlePaneExitHandlerType = @import("../../application/panes/HandlePaneExitHandler.zig");
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const PaneClosureType = @import("../../model/PaneClosure.zig");
const DeliverPaneClosureHandlerType = @import("../../application/panes/DeliverPaneClosureHandler.zig");
const pane_geometry = @import("pane_geometry.zig");
const PaneIdType = @import("telar-core").PaneId;
const active_pane_resources = @import("active_pane_resources.zig");
const RectType = @import("telar-core").Rect;

/// Wires an interactive close request to the client request tracker and wire.
///
/// ```zig
/// var handler = requestHandler(client);
/// _ = try handler.execute();
/// ```
pub fn requestHandler(client: *Client) RequestClosePaneHandlerType {
    return .{
        .model = &client.model,
        .gate = .{
            .context = client,
            .pending = paneOperationPending,
        },
        .effects = .{
            .context = client,
            .send = sendClosure,
        },
    };
}

/// Translates one authoritative pane exit into model commit and cleanup.
///
/// ```zig
/// const transition = try applyExit(client, exited);
/// ```
pub fn applyExit(client: *Client, exited: PaneExitedType) !PaneExitType {
    var use_case = exitHandler(client);

    return use_case.execute(exited.pane_id);
}

fn exitHandler(client: *Client) HandlePaneExitHandlerType {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .deliver = deliverExit,
        },
    };
}

fn paneOperationPending(context: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(context));
    return request_lifecycle.has(client, .pane_operation);
}

fn sendClosure(context: *anyopaque, closure: PaneClosureType) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const request_id = try request_lifecycle.nextId(client);
    try request_lifecycle.deliver(client, .{
        .registration = .{
            .request_id = request_id,
            .continuation = .{ .close_pane = .{
                .pane_id = closure.pane_id,
                .location = closure.location,
            } },
        },
        .message = .{ .close_pane = .{
            .request_id = request_id,
            .pane_id = closure.pane_id,
        } },
    });
}

fn deliverExit(context: *anyopaque, transition: PaneExitType) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    var use_case: DeliverPaneClosureHandlerType = .{
        .model = &client.model,
        .geometry_effects = pane_geometry.offerEffects(client),
        .effects = .{
            .context = client,
            .ignore_attachment = ignoreAttachment,
            .complete_close = completeClose,
            .clear_pane_graphics = clearPaneGraphics,
            .invalidate_graphics_placements = invalidateGraphicsPlacements,
            .synchronize_active_resources = synchronizeActiveResources,
            .active_geometry_area = activeGeometryArea,
        },
    };

    try use_case.execute(transition);
}

fn ignoreAttachment(context: *anyopaque, pane_id: PaneIdType) void {
    const client: *Client = @ptrCast(@alignCast(context));

    _ = request_lifecycle.ignoreAttachment(client, pane_id);
}

fn completeClose(context: *anyopaque, pane_id: PaneIdType) void {
    const client: *Client = @ptrCast(@alignCast(context));

    _ = request_lifecycle.completePaneClose(client, pane_id);
}

fn clearPaneGraphics(context: *anyopaque, pane_id: PaneIdType) void {
    const client: *Client = @ptrCast(@alignCast(context));

    client.graphics.clearPane(pane_id);
}

fn invalidateGraphicsPlacements(context: *anyopaque) void {
    const client: *Client = @ptrCast(@alignCast(context));

    client.host_graphics.invalidatePlacements();
}

fn synchronizeActiveResources(context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try active_pane_resources.synchronize(client);
}

fn activeGeometryArea(context: *anyopaque) RectType {
    const client: *Client = @ptrCast(@alignCast(context));

    return client.geometry().area;
}
