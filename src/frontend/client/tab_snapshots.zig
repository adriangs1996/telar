//! Client resource reconciliation after canonical tab snapshots.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../workspace/root.zig");
const client_application = @import("application/root.zig");
const client_model = @import("model.zig");
const tab_attachments = @import("tab_attachments.zig");

const Client = @import("client.zig");
const schema = core.schema;
const tabs_mod = workspace_capability.tabs;
const tab_snapshot = client_application.tab_snapshot;

/// Wires canonical pane membership to focus, attachment and resource repair.
///
/// ```zig
/// var handler = reconciliationHandler(client);
/// try handler.execute(snapshot);
/// ```
pub fn reconciliationHandler(client: *Client) tab_snapshot.ApplyTabSnapshotHandler {
    return .{
        .model = &client.model,
        .area = client.view.workbench(),
        .effects = .{
            .context = client,
            .apply = applyReconciliation,
        },
    };
}

fn applyReconciliation(context: *anyopaque, reconciliation: *const client_model.TabReconciliation) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    for (reconciliation.removed_panes.slice()) |pane_id| {
        client.requests.ignorePane(pane_id);
        tab_attachments.releasePaneState(client, pane_id);
    }

    const tab = findTab(client, reconciliation.location) orelse
        return error.UnexpectedTabReconciliation;
    if (!reconciliation.active) {
        return;
    }

    const active = client.model.workspace.active() orelse
        return error.UnexpectedTabReconciliation;
    if (active != tab) {
        return error.UnexpectedTabReconciliation;
    }

    try client.syncPaneFocus(&tab.model);
    try client.resizeAttached(&tab.model, client.view.workbench());
    var panes = tab.model.paneIterator();
    while (panes.next()) |pane| {
        if (pane.attached or client.requests.hasPane(.attachment, pane.id)) {
            continue;
        }

        const size = tab.model.contentSize(pane.id, client.view.workbench()) orelse
            return error.PaneTooSmall;
        const request_id = try client.nextId();
        try client.enqueueRequest(
            request_id,
            .{ .attach_pane = .{
                .pane_id = pane.id,
                .location = tab.location,
            } },
            .{ .open_pane = .{
                .request_id = request_id,
                .target = .{ .pane = pane.id },
                .size = size,
                .launch = null,
            } },
        );
    }
}

fn findTab(client: *Client, location: schema.TabLocation) ?*tabs_mod.Tab {
    const tab = client.model.workspace.find(location.tab_id) orelse return null;
    if (!std.meta.eql(tab.location, location)) {
        return null;
    }

    return tab;
}
