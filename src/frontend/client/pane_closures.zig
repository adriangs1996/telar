//! Wires pane closure and exit use cases to one disposable client.

const core = @import("telar-core");
const client_application = @import("application/root.zig");
const client_model = @import("model.zig");
const active_pane_resources = @import("active_pane_resources.zig");
const pane_geometry = @import("pane_geometry.zig");
const request_lifecycle = @import("request_lifecycle.zig");

const Client = @import("client.zig");
const close_pane = client_application.close_pane;
const pane_closure_delivery = client_application.pane_closure_delivery;
const schema = core.schema;

/// Wires an interactive close request to the client request tracker and wire.
///
/// ```zig
/// var handler = requestHandler(client);
/// _ = try handler.execute();
/// ```
pub fn requestHandler(client: *Client) close_pane.RequestClosePaneHandler {
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
pub fn applyExit(client: *Client, exited: schema.PaneExited) !client_model.PaneExit {
    var use_case = exitHandler(client);

    return use_case.execute(exited.pane_id);
}

fn exitHandler(client: *Client) close_pane.HandlePaneExitHandler {
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

fn sendClosure(context: *anyopaque, closure: client_model.PaneClosure) !void {
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

fn deliverExit(context: *anyopaque, transition: client_model.PaneExit) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    var use_case: pane_closure_delivery.DeliverPaneClosureHandler = .{
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

fn ignoreAttachment(context: *anyopaque, pane_id: schema.PaneId) void {
    const client: *Client = @ptrCast(@alignCast(context));

    _ = request_lifecycle.ignoreAttachment(client, pane_id);
}

fn completeClose(context: *anyopaque, pane_id: schema.PaneId) void {
    const client: *Client = @ptrCast(@alignCast(context));

    _ = request_lifecycle.completePaneClose(client, pane_id);
}

fn clearPaneGraphics(context: *anyopaque, pane_id: schema.PaneId) void {
    const client: *Client = @ptrCast(@alignCast(context));

    client.graphics_store.clearPane(pane_id);
}

fn invalidateGraphicsPlacements(context: *anyopaque) void {
    const client: *Client = @ptrCast(@alignCast(context));

    client.graphics_store.invalidatePlacements();
}

fn synchronizeActiveResources(context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try active_pane_resources.synchronize(client);
}

fn activeGeometryArea(context: *anyopaque) core.ui.Rect {
    const client: *Client = @ptrCast(@alignCast(context));

    return client.view.workbench();
}
