//! Wires pane closure and exit use cases to one disposable client.

const std = @import("std");
const core = @import("telar-core");
const client_application = @import("application/root.zig");
const client_model = @import("model.zig");
const pane_resources = @import("pane_resources.zig");

const Client = @import("client.zig");
const close_pane = client_application.close_pane;
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

/// Wires an authoritative pane exit to model commit and resource cleanup.
///
/// ```zig
/// var handler = exitHandler(client);
/// _ = try handler.execute(pane_id);
/// ```
pub fn exitHandler(client: *Client) close_pane.HandlePaneExitHandler {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .apply = applyExit,
        },
    };
}

fn paneOperationPending(context: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(context));
    return client.requests.has(.pane_operation);
}

fn sendClosure(context: *anyopaque, closure: client_model.PaneClosure) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const request_id = try client.nextId();
    try client.enqueueRequest(
        request_id,
        .{ .close_pane = .{
            .pane_id = closure.pane_id,
            .location = closure.location,
        } },
        .{ .close_pane = .{
            .request_id = request_id,
            .pane_id = closure.pane_id,
        } },
    );
}

fn applyExit(context: *anyopaque, transition: client_model.PaneExit) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const pane_id = switch (transition) {
        .retired => |retired| retired.pane_id,
        .stale => |stale| stale,
    };
    _ = client.requests.ignoreAttachment(pane_id);
    _ = client.requests.completePaneClose(pane_id);
    pane_resources.release(client, pane_id);

    const retirement = switch (transition) {
        .retired => |retired| retired,
        .stale => return,
    };
    if (!retirement.active) {
        return;
    }

    const active = client.model.workspace.active() orelse
        return error.UnexpectedPaneExit;
    if (!std.meta.eql(active.location, retirement.location)) {
        return error.UnexpectedPaneExit;
    }

    client.graphics_store.invalidatePlacements();
    try client.syncPaneFocus(&active.model);
    if (!retirement.tab_empty) {
        try client.resizeAttached(&active.model, client.view.workbench());
    }
}
