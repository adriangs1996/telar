//! Tab snapshot: requests a tab's canonical panes and reconciles the local
//! layout with them.
const core = @import("telar-core");
const std = @import("std");
const runtime_io = @import("../connection/runtime_io.zig");
const pane_attachment = @import("../panes/pane_attachment.zig");
const pane_closure = @import("../panes/pane_closure.zig");
const pane_focus = @import("../panes/pane_focus.zig");
const pane_resize = @import("../panes/pane_resize.zig");
const Client = @import("../execution/Client.zig");
const data = @import("model");

const TabSnapshotOutcome = enum { applied, ignored };

const TabSnapshotRecovery = enum { coalesced, requested };

/// Requests a canonical snapshot with its exact target retained until the reply.
/// Example: `try tab_snapshot.requestTabSnapshot(client, location);`
pub fn requestTabSnapshot(model: *data.ClientModel, location: core.TabLocation) !void {
    const request_id = try model.request_lifecycle.nextId();
    try runtime_io.sendRuntimeRequest(
        model,
        .{
            .registration = .{
                .request_id = request_id,
                .continuation = .{
                    .tab_snapshot = location,
                },
            },
            .message = .{
                .request_tab_snapshot = .{
                    .request_id = request_id,
                    .location = location,
                },
            },
        },
    );
}

/// Example: `try tab_snapshot.recoverTabSnapshot(app, location);`
pub fn recoverTabSnapshot(model: *data.ClientModel, location: core.TabLocation) !TabSnapshotRecovery {
    if (model.request_lifecycle.tracker.has(.tab_snapshot)) {
        return .coalesced;
    }

    try requestTabSnapshot(model, location);
    return .requested;
}

pub fn applyTabSnapshot(client: *Client, snapshot: core.TabSnapshotView) !TabSnapshotOutcome {
    const continuation = client.model.request_lifecycle.tracker.take(snapshot.request_id) orelse
        return error.UnexpectedTabSnapshot;
    const expected_location = switch (continuation) {
        .tab_snapshot => |location| location,
        .ignored => return .ignored,
        else => return error.UnexpectedTabSnapshot,
    };

    if (!std.meta.eql(expected_location, snapshot.location)) {
        return error.UnexpectedTabSnapshot;
    }

    var pane_ids: [core.max_panes_per_tab]core.PaneId = undefined;
    var pane_count: usize = 0;
    var panes = snapshot.panes();
    while (try panes.next()) |pane| {
        if (pane_count == pane_ids.len) {
            return error.TooManyPanes;
        }

        pane_ids[pane_count] = pane.pane_id;
        pane_count += 1;
    }

    const reconciliation = try client.model.reconcileTab(
        .{
            .location = snapshot.location,
            .panes = pane_ids[0..pane_count],
        },
        client.geometry().area,
    );

    for (reconciliation.removed_panes.slice()) |pane_id| {
        client.model.request_lifecycle.tracker.ignorePane(pane_id);
        pane_closure.releasePaneResources(client, pane_id);
    }

    if (reconciliation.active) {
        const tab = client.model.tabs.find(reconciliation.location.tab_id) orelse return error.StaleTabReconciliation;
        try pane_focus.synchronizeActivePane(client);
        try pane_resize.resizeAttachedPanes(client, tab, reconciliation.area);
        try pane_attachment.attachVisiblePanes(&client.model, tab, reconciliation.area);
    }

    return .applied;
}
