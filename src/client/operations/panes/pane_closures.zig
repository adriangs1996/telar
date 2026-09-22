const Client = @import("../../AttachedClient.zig");
const pane_resources = @import("pane_resources.zig");
const PaneClosureType = @import("../../model/PaneClosure.zig");
const types = @import("../../model/types.zig");

const PaneExited = @import("telar-core").PaneExited;

/// Requests closure without mutating runtime-owned pane membership. Example: `_ = try request(client);`
pub fn request(client: *Client) !?PaneClosureType {
    if (client.request_lifecycle.tracker.has(.pane_operation)) {
        return null;
    }

    const closure = client.model.planPaneClosure() orelse return null;
    const request_id = try client.request_lifecycle.nextId();
    try client.sendRuntimeRequest(.{
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
    return closure;
}

/// Commits authoritative retirement and performs idempotent cleanup for late exits. Example: `_ = try applyExit(client, exited);`
pub fn applyExit(client: *Client, exited: PaneExited) !types.PaneExit {
    const transition = client.model.retirePane(exited.pane_id);
    _ = client.request_lifecycle.tracker.ignoreAttachment(exited.pane_id);
    _ = client.request_lifecycle.tracker.completePaneClose(exited.pane_id);
    pane_resources.release(client, exited.pane_id);

    const retirement = switch (transition) {
        .retired => |retirement| retirement,
        .stale => return transition,
    };
    if (!retirement.active) {
        return transition;
    }

    client.host_graphics.invalidatePlacements();
    try client.synchronizeActivePane();
    if (!retirement.tab_empty) {
        const tab = client.model.workspace.find(retirement.location.tab_id) orelse return error.StalePaneExit;
        try client.resizeAttachedPanes(&tab.model, client.geometry().area);
    }

    return transition;
}
