//! Client resource reconciliation after canonical workspace snapshots.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../workspace/root.zig");
const client_application = @import("application/root.zig");
const client_model = @import("model.zig");
const tab_attachments = @import("tab_attachments.zig");

const Client = @import("client.zig");
const schema = core.schema;
const tabs_mod = workspace_capability.tabs;
const workspace_snapshot = client_application.workspace_snapshot;

/// Wires canonical workspace state to request, focus and attachment cleanup.
///
/// ```zig
/// var handler = reconciliationHandler(client);
/// try handler.execute(snapshot);
/// ```
pub fn reconciliationHandler(client: *Client) workspace_snapshot.ApplyWorkspaceSnapshotHandler {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .apply = applyReconciliation,
        },
    };
}

fn applyReconciliation(context: *anyopaque, reconciliation: *const client_model.WorkspaceReconciliation) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    for (reconciliation.removed_tabs.slice()) |location| {
        client.requests.ignoreTab(location.tab_id);
    }

    for (reconciliation.removed_panes.slice()) |pane_id| {
        tab_attachments.releasePaneState(client, pane_id);
    }

    const active = findActive(client, reconciliation.active) orelse
        return error.UnexpectedWorkspaceReconciliation;
    if (reconciliation.active_tab_changed) {
        client.forgetPaneFocus();
        var panes = active.model.paneIterator();
        while (panes.next()) |pane| {
            try client.graphics_store.setPaneVisible(pane.id, true);
        }

        try client.syncPaneFocus(&active.model);
    }

    if (client.requests.has(.tab_snapshot)) {
        return;
    }

    if (reconciliation.active_tab_changed or !active.snapshot_loaded) {
        try client.requestTabSnapshot(active.location);
        return;
    }

    try client.resizeAttached(&active.model, client.view.workbench());
}

fn findActive(client: *Client, location: schema.TabLocation) ?*tabs_mod.Tab {
    const active = client.model.workspace.active() orelse return null;
    if (!std.meta.eql(active.location, location)) {
        return null;
    }

    return active;
}
