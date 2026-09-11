//! Client resource reconciliation after canonical workspace snapshots.

const Client = @import("../../Client.zig");
const WorkspaceSnapshotViewType = @import("telar-core").WorkspaceSnapshotView;
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const std = @import("std");
const max_tabs_per_workspace = @import("telar-core").max_tabs_per_workspace;
const WorkspaceTabInputType = @import("telar-client").WorkspaceTabInput;
const ApplyWorkspaceSnapshotHandlerType = @import("telar-client").ApplyWorkspaceSnapshotHandler;
const WorkspaceReconciliationType = @import("telar-client").WorkspaceReconciliation;
const DeliverWorkspaceSnapshotHandlerType = @import("telar-client").DeliverWorkspaceSnapshotHandler;
const pane_geometry = @import("../panes/pane_geometry.zig");
const TabIdType = @import("telar-core").TabId;
const PaneIdType = @import("telar-core").PaneId;
const active_pane_resources = @import("../panes/active_pane_resources.zig");
const TabLocationType = @import("telar-core").TabLocation;

/// Consumes one correlated response and applies its canonical workspace state.
///
/// ```zig
/// try apply(client, snapshot);
/// ```
pub fn apply(client: *Client, snapshot: WorkspaceSnapshotViewType) !void {
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

    var tabs: [max_tabs_per_workspace]WorkspaceTabInputType = undefined;
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

fn reconciliationHandler(client: *Client) ApplyWorkspaceSnapshotHandlerType {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .deliver = deliverReconciliation,
        },
    };
}

fn deliverReconciliation(context: *anyopaque, reconciliation: *const WorkspaceReconciliationType) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    var use_case: DeliverWorkspaceSnapshotHandlerType = .{
        .model = &client.model,
        .area = client.geometry().area,
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

fn ignoreTabRequests(context: *anyopaque, tab_id: TabIdType) void {
    const client: *Client = @ptrCast(@alignCast(context));

    request_lifecycle.ignoreTab(client, tab_id);
}

fn clearPaneGraphics(context: *anyopaque, pane_id: PaneIdType) void {
    const client: *Client = @ptrCast(@alignCast(context));

    client.graphics_store.clearPane(pane_id);
}

fn setPaneGraphicsVisible(context: *anyopaque, pane_id: PaneIdType, visible: bool) !void {
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

fn requestTabSnapshot(context: *anyopaque, location: TabLocationType) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try request_lifecycle.requestTabSnapshot(client, location);
}
