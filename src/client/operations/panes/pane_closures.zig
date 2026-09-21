const Client = @import("../../AttachedClient.zig");
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const pane_geometry = @import("pane_geometry.zig");
const pane_resources = @import("pane_resources.zig");
const active_pane_resources = @import("active_pane_resources.zig");
const PaneClosureType = @import("../../model/PaneClosure.zig");
const types = @import("../../model/types.zig");

const PaneExited = @import("telar-core").PaneExited;

/// Requests closure without mutating runtime-owned pane membership. Example: `_ = try request(client);`
pub fn request(client: *Client) !?PaneClosureType {
    if (request_lifecycle.has(client, .pane_operation)) {
        return null;
    }

    const closure = client.model.planPaneClosure() orelse return null;
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
    return closure;
}

/// Commits authoritative retirement and performs idempotent cleanup for late exits. Example: `_ = try applyExit(client, exited);`
pub fn applyExit(client: *Client, exited: PaneExited) !types.PaneExit {
    const transition = client.model.retirePane(exited.pane_id);
    _ = request_lifecycle.ignoreAttachment(client, exited.pane_id);
    _ = request_lifecycle.completePaneClose(client, exited.pane_id);
    pane_resources.release(client, exited.pane_id);

    const retirement = switch (transition) {
        .retired => |retirement| retirement,
        .stale => return transition,
    };
    if (!retirement.active) {
        return transition;
    }

    client.host_graphics.invalidatePlacements();
    try active_pane_resources.synchronize(client);
    if (!retirement.tab_empty) {
        const tab = client.model.workspace.find(retirement.location.tab_id) orelse return error.StalePaneExit;
        try pane_geometry.offerAttached(client, &tab.model, client.geometry().area);
    }

    return transition;
}
