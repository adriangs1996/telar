//! Workspace list snapshot: requests and applies the runtime's list of
//! workspaces.
const data = @import("model");
const core = @import("telar-core");
const std = @import("std");
const runtime_io = @import("../connection/runtime_io.zig");
const pane_closure = @import("../panes/pane_closure.zig");
const pane_focus = @import("../panes/pane_focus.zig");
const pane_resize = @import("../panes/pane_resize.zig");
const tab_snapshot = @import("tab_snapshot.zig");
const Client = @import("../AttachedClient.zig");

/// Requests a canonical snapshot with its exact target retained until the reply.
/// Example: `try workspace_list_snapshot.requestWorkspaceSnapshot(client, workspace);`
pub fn requestWorkspaceSnapshot(model: *data.ClientModel, workspace: core.WorkspaceLocation) !void {
    const request_id = try model.request_lifecycle.nextId();
    try runtime_io.sendRuntimeRequest(
        model,
        .{
            .registration = .{
                .request_id = request_id,
                .continuation = .{
                    .workspace_snapshot = workspace,
                },
            },
            .message = .{
                .request_workspace_snapshot = .{
                    .request_id = request_id,
                    .workspace = workspace,
                },
            },
        },
    );
}

pub fn applyWorkspaceSnapshot(client: *Client, snapshot: core.WorkspaceSnapshotView) !void {
    const continuation = client.model.request_lifecycle.tracker.take(snapshot.request_id) orelse
        return error.UnexpectedWorkspaceSnapshot;
    const expected_workspace = switch (continuation) {
        .workspace_snapshot => |workspace| workspace,
        .rename_workspace => |workspace| workspace,
        else => return error.UnexpectedWorkspaceSnapshot,
    };

    if (!std.meta.eql(expected_workspace, snapshot.workspace)) {
        return error.UnexpectedWorkspaceSnapshot;
    }

    var tabs: [core.max_tabs_per_workspace]data.WorkspaceTabInput = undefined;
    var foregrounds: [core.max_tabs_per_workspace][core.max_panes_per_tab]core.PaneForeground = undefined;
    var tab_count: usize = 0;
    var iterator = snapshot.tabs();
    while (try iterator.next()) |tab| {
        if (tab_count == tabs.len) {
            return error.TooManyTabs;
        }

        var names = tab.foregrounds();
        var name_count: usize = 0;
        while (try names.next()) |foreground| {
            if (name_count == core.max_panes_per_tab) {
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

    const reconciliation = try client.model.reconcileWorkspace(
        .{
            .workspace = snapshot.workspace,
            .name = snapshot.name,
            .tabs = tabs[0..tab_count],
        },
    );
    for (reconciliation.removed_tabs.slice()) |location| {
        client.model.request_lifecycle.tracker.ignoreTab(location.tab_id);
    }

    for (reconciliation.removed_panes.slice()) |pane_id| {
        pane_closure.releasePaneResources(client, pane_id);
    }

    const active = client.model.tabs.activeSlot() orelse return error.StaleWorkspaceReconciliation;
    if (reconciliation.active_tab_changed) {
        _ = client.model.forgetReportedPaneFocus();
        var panes = client.model.panes.iterate(client.model.tabs.location[active].tab_id);
        while (panes.next()) |pane| {
            try client.graphics.setPaneVisible(pane.id, true);
        }

        try pane_focus.synchronizeActivePane(client);
    }

    if (client.model.request_lifecycle.tracker.has(.tab_snapshot)) {
        return;
    }

    if (reconciliation.active_tab_changed or !reconciliation.active_snapshot_loaded) {
        try tab_snapshot.requestTabSnapshot(&client.model, reconciliation.active);
        return;
    }

    try pane_resize.resizeAttachedPanes(client, active, client.geometry().area);
}
