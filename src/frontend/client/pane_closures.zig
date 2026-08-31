//! Wires pane closure and exit use cases to one disposable client.

const std = @import("std");
const core = @import("telar-core");
const client_application = @import("application/root.zig");
const client_model = @import("model.zig");
const active_pane_resources = @import("active_pane_resources.zig");
const pane_geometry = @import("pane_geometry.zig");
const pane_resources = @import("pane_resources.zig");
const request_lifecycle = @import("request_lifecycle.zig");

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
            .apply = applyExitEffects,
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

fn applyExitEffects(context: *anyopaque, transition: client_model.PaneExit) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const pane_id = switch (transition) {
        .retired => |retired| retired.pane_id,
        .stale => |stale| stale,
    };
    _ = request_lifecycle.ignoreAttachment(client, pane_id);
    _ = request_lifecycle.completePaneClose(client, pane_id);
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
    try active_pane_resources.synchronize(client);
    if (!retirement.tab_empty) {
        try pane_geometry.offerAttached(client, &active.model, client.view.workbench());
    }
}
