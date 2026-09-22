//! Client resource reconciliation after canonical workspace snapshots.

const Client = @import("../../AttachedClient.zig");
const WorkspaceSnapshotViewType = @import("telar-core").WorkspaceSnapshotView;
const std = @import("std");
const max_tabs_per_workspace = @import("telar-core").max_tabs_per_workspace;
const WorkspaceTabInputType = @import("../../workspace/WorkspaceTabInput.zig");
const PaneForeground = @import("telar-core").PaneForeground;
const max_panes_per_tab = @import("telar-core").max_panes_per_tab;

const pane_resources = @import("../panes/pane_resources.zig");

/// Applies correlated canonical state, retires resources and repairs active geometry. Example: `try apply(client, snapshot);`
pub fn apply(client: *Client, snapshot: WorkspaceSnapshotViewType) !void {
    const continuation = client.request_lifecycle.tracker.take(snapshot.request_id) orelse
        return error.UnexpectedWorkspaceSnapshot;
    const expected_workspace = switch (continuation) {
        .workspace_snapshot => |workspace| workspace,
        .rename_workspace => |workspace| workspace,
        else => return error.UnexpectedWorkspaceSnapshot,
    };
    if (!std.meta.eql(expected_workspace, snapshot.workspace)) {
        return error.UnexpectedWorkspaceSnapshot;
    }

    var tabs: [max_tabs_per_workspace]WorkspaceTabInputType = undefined;
    var foregrounds: [max_tabs_per_workspace][max_panes_per_tab]PaneForeground = undefined;
    var tab_count: usize = 0;
    var iterator = snapshot.tabs();
    while (try iterator.next()) |tab| {
        if (tab_count == tabs.len) {
            return error.TooManyTabs;
        }

        var names = tab.foregrounds();
        var name_count: usize = 0;
        while (try names.next()) |foreground| {
            if (name_count == max_panes_per_tab) {
                return error.TooManyPanes;
            }

            foregrounds[tab_count][name_count] = foreground;
            name_count += 1;
        }

        tabs[tab_count] = .{
            .tab_id = tab.tab_id,
            .pane_count = tab.pane_count,
            .label = tab.label,
            .foregrounds = foregrounds[tab_count][0..name_count],
        };
        tab_count += 1;
    }

    const reconciliation = try client.model.reconcileWorkspace(.{
        .workspace = snapshot.workspace,
        .name = snapshot.name,
        .tabs = tabs[0..tab_count],
    });
    for (reconciliation.removed_tabs.slice()) |location| {
        client.request_lifecycle.tracker.ignoreTab(location.tab_id);
    }

    for (reconciliation.removed_panes.slice()) |pane_id| {
        pane_resources.release(client, pane_id);
    }

    const active = client.model.workspace.active() orelse return error.StaleWorkspaceReconciliation;
    if (reconciliation.active_tab_changed) {
        _ = client.model.forgetReportedPaneFocus();
        var panes = active.model.paneIterator();
        while (panes.next()) |pane| {
            try client.graphics.setPaneVisible(pane.id, true);
        }

        try client.synchronizeActivePane();
    }

    if (client.request_lifecycle.tracker.has(.tab_snapshot)) {
        return;
    }

    if (reconciliation.active_tab_changed or !reconciliation.active_snapshot_loaded) {
        try client.requestTabSnapshot(reconciliation.active);
        return;
    }

    try client.resizeAttachedPanes(&active.model, client.geometry().area);
}
