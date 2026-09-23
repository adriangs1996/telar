//! Pane closure: closes a pane and releases what it held when its child exits.
const data = @import("model");
const core = @import("telar-core");
const runtime_io = @import("../connection/runtime_io.zig");
const pane_focus = @import("pane_focus.zig");
const pane_resize = @import("pane_resize.zig");
const Client = @import("../AttachedClient.zig");

/// Requests closure without mutating runtime-owned pane membership.
pub fn requestPaneClose(client: *Client) !?data.PaneClosure {
    if (client.model.request_lifecycle.tracker.has(.pane_operation)) {
        return null;
    }

    const closure = client.model.planPaneClosure() orelse return null;
    const request_id = try client.model.request_lifecycle.nextId();
    try runtime_io.sendRuntimeRequest(
        client,
        .{
            .registration = .{
                .request_id = request_id,
                .continuation = .{
                    .close_pane = .{
                        .pane_id = closure.pane_id,
                        .location = closure.location,
                    },
                },
            },
            .message = .{
                .close_pane = .{
                    .request_id = request_id,
                    .pane_id = closure.pane_id,
                },
            },
        },
    );
    return closure;
}

/// Commits authoritative retirement and performs idempotent cleanup for late exits.
pub fn applyPaneExit(client: *Client, exited: core.PaneExited) !data.PaneExit {
    const transition = client.model.retirePane(exited.pane_id);
    _ = client.model.request_lifecycle.tracker.ignoreAttachment(exited.pane_id);
    _ = client.model.request_lifecycle.tracker.completePaneClose(exited.pane_id);
    releasePaneResources(client, exited.pane_id);

    const retirement = switch (transition) {
        .retired => |retirement| retirement,
        .stale => return transition,
    };

    if (!retirement.active) {
        return transition;
    }

    client.model.to_host.invalidate_placements = true;
    try pane_focus.synchronizeActivePane(client);
    if (!retirement.tab_empty) {
        const tab = client.model.tabs.find(retirement.location.tab_id) orelse return error.StalePaneExit;
        try pane_resize.resizeAttachedPanes(client, tab, client.geometry().area);
    }

    return transition;
}

/// Releases exact pane authorities before physical resources; repeated release is harmless.
pub fn releasePaneResources(client: *Client, pane_id: core.PaneId) void {
    _ = client.model.releaseCopyMode(pane_id);
    _ = client.model.releasePanePaste(pane_id);
    _ = client.model.releaseReportedPaneFocus(pane_id);
    client.graphics.clearPane(pane_id);
}
