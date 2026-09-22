//! Client resource reconciliation after canonical tab snapshots.

const Client = @import("../../AttachedClient.zig");
const TabSnapshotViewType = @import("telar-core").TabSnapshotView;
const std = @import("std");
const max_panes_per_tab_module = @import("telar-core").max_panes_per_tab;
const PaneIdType = @import("telar-core").PaneId;

const pane_resources = @import("../panes/pane_resources.zig");

const TabLocation = @import("telar-core").TabLocation;
pub const Outcome = enum { applied, ignored };
pub const Recovery = enum { coalesced, requested };

/// Commits correlated membership before releasing panes and repairing attachments. Example: `_ = try apply(client, snapshot);`
pub fn apply(client: *Client, snapshot: TabSnapshotViewType) !Outcome {
    const continuation = client.request_lifecycle.tracker.take(snapshot.request_id) orelse
        return error.UnexpectedTabSnapshot;
    const expected_location = switch (continuation) {
        .tab_snapshot => |location| location,
        .ignored => return .ignored,
        else => return error.UnexpectedTabSnapshot,
    };
    if (!std.meta.eql(expected_location, snapshot.location)) {
        return error.UnexpectedTabSnapshot;
    }

    var pane_ids: [max_panes_per_tab_module]PaneIdType = undefined;
    var pane_count: usize = 0;
    var panes = snapshot.panes();
    while (try panes.next()) |pane| {
        if (pane_count == pane_ids.len) {
            return error.TooManyPanes;
        }

        pane_ids[pane_count] = pane.pane_id;
        pane_count += 1;
    }

    const reconciliation = try client.model.reconcileTab(.{
        .location = snapshot.location,
        .panes = pane_ids[0..pane_count],
    }, client.geometry().area);

    for (reconciliation.removed_panes.slice()) |pane_id| {
        client.request_lifecycle.tracker.ignorePane(pane_id);
        pane_resources.release(client, pane_id);
    }

    if (reconciliation.active) {
        const tab = client.model.workspace.find(reconciliation.location.tab_id) orelse return error.StaleTabReconciliation;
        try client.synchronizeActivePane();
        try client.resizeAttachedPanes(&tab.model, reconciliation.area);
        try client.attachVisiblePanes(tab, reconciliation.area);
    }

    return .applied;
}

/// Coalesces snapshot recovery until the pending response settles. Example: `_ = try recover(client, location);`
pub fn recover(client: *Client, location: TabLocation) !Recovery {
    if (client.request_lifecycle.tracker.has(.tab_snapshot)) {
        return .coalesced;
    }

    try client.requestTabSnapshot(location);
    return .requested;
}
