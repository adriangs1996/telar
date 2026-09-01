//! Client resource reconciliation after canonical workspace snapshots.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../../../workspace/root.zig");
const workspaces_application = @import("../../application/workspaces/root.zig");
const client_model = @import("../../model/root.zig");
const active_pane_resources = @import("../panes/active_pane_resources.zig");
const pane_geometry = @import("../panes/pane_geometry.zig");
const request_lifecycle = @import("../../connection/request_lifecycle.zig");

const Client = @import("../../client.zig");
const schema = core.schema;
const tabs_mod = workspace_capability.tabs;
const workspace_snapshot = workspaces_application.workspace_snapshot;
const workspace_snapshot_delivery = workspaces_application.workspace_snapshot_delivery;

/// Consumes one correlated response and applies its canonical workspace state.
///
/// ```zig
/// try apply(client, snapshot);
/// ```
pub fn apply(client: *Client, snapshot: schema.WorkspaceSnapshotView) !void {
    const continuation = request_lifecycle.consume(client, snapshot.request_id) orelse
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
            .deliver = deliverReconciliation,
        },
    };
}

fn deliverReconciliation(context: *anyopaque, reconciliation: *const client_model.WorkspaceReconciliation) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    var use_case: workspace_snapshot_delivery.DeliverWorkspaceSnapshotHandler = .{
        .model = &client.model,
        .area = client.view.workbench(),
        .geometry_effects = pane_geometry.offerEffects(client),
        .effects = .{
            .context = client,
            .ignore_tab_requests = ignoreTabRequests,
            .clear_pane_graphics = clearPaneGraphics,
            .set_pane_graphics_visible = setPaneGraphicsVisible,
            .synchronize_active_resources = synchronizeActiveResources,
            .tab_snapshot_pending = tabSnapshotPending,
            .request_tab_snapshot = requestTabSnapshot,
        },
    };

    try use_case.execute(reconciliation);
}

fn ignoreTabRequests(context: *anyopaque, tab_id: schema.TabId) void {
    const client: *Client = @ptrCast(@alignCast(context));

    request_lifecycle.ignoreTab(client, tab_id);
}

fn clearPaneGraphics(context: *anyopaque, pane_id: schema.PaneId) void {
    const client: *Client = @ptrCast(@alignCast(context));

    client.graphics_store.clearPane(pane_id);
}

fn setPaneGraphicsVisible(context: *anyopaque, pane_id: schema.PaneId, visible: bool) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try client.graphics_store.setPaneVisible(pane_id, visible);
}

fn synchronizeActiveResources(context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try active_pane_resources.synchronize(client);
}

fn tabSnapshotPending(context: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(context));

    return request_lifecycle.has(client, .tab_snapshot);
}

fn requestTabSnapshot(context: *anyopaque, location: schema.TabLocation) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try request_lifecycle.requestTabSnapshot(client, location);
}
