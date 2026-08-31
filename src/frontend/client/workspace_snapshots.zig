//! Client resource reconciliation after canonical workspace snapshots.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../workspace/root.zig");
const client_application = @import("application/root.zig");
const client_model = @import("model.zig");
const pane_focus = @import("pane_focus.zig");
const pane_resources = @import("pane_resources.zig");

const Client = @import("client.zig");
const schema = core.schema;
const tabs_mod = workspace_capability.tabs;
const workspace_snapshot = client_application.workspace_snapshot;

/// Consumes one correlated response and applies its canonical workspace state.
///
/// ```zig
/// try apply(client, snapshot);
/// ```
pub fn apply(client: *Client, snapshot: schema.WorkspaceSnapshotView) !void {
    const continuation = client.requests.take(snapshot.request_id) orelse
        return error.UnexpectedWorkspaceSnapshot;
    const expected_workspace = switch (continuation) {
        .workspace_snapshot => |workspace| workspace,
        .rename_workspace => |workspace| workspace,
        else => return error.UnexpectedWorkspaceSnapshot,
    };
    if (!std.meta.eql(expected_workspace, snapshot.workspace)) {
        return error.UnexpectedWorkspaceSnapshot;
    }

    var tabs: [tabs_mod.max_tabs]tabs_mod.WorkspaceTabInput = undefined;
    var tab_count: usize = 0;
    var iterator = snapshot.tabs();
    while (try iterator.next()) |tab| {
        if (tab_count == tabs.len) {
            return error.TooManyTabs;
        }

        tabs[tab_count] = .{
            .tab_id = tab.tab_id,
            .pane_count = tab.pane_count,
            .label = tab.label,
        };
        tab_count += 1;
    }

    var use_case = reconciliationHandler(client);
    try use_case.execute(.{
        .workspace = snapshot.workspace,
        .name = snapshot.name,
        .tabs = tabs[0..tab_count],
    });
}

fn reconciliationHandler(client: *Client) workspace_snapshot.ApplyWorkspaceSnapshotHandler {
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
        pane_resources.release(client, pane_id);
    }

    const active = findActive(client, reconciliation.active) orelse
        return error.UnexpectedWorkspaceReconciliation;
    if (reconciliation.active_tab_changed) {
        _ = client.model.forgetReportedPaneFocus();
        var panes = active.model.paneIterator();
        while (panes.next()) |pane| {
            try client.graphics_store.setPaneVisible(pane.id, true);
        }

        try pane_focus.syncResources(client);
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
