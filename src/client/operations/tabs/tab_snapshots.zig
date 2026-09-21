//! Client resource reconciliation after canonical tab snapshots.

const Client = @import("../../AttachedClient.zig");
const TabSnapshotViewType = @import("telar-core").TabSnapshotView;
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const std = @import("std");
const max_panes_per_tab_module = @import("telar-core").max_panes_per_tab;
const PaneIdType = @import("telar-core").PaneId;
const RectType = @import("telar-core").Rect;
const pane_geometry = @import("../panes/pane_geometry.zig");
const active_pane_resources = @import("../panes/active_pane_resources.zig");
const PaneAttachmentRequestType = @import("../../application/panes/PaneAttachmentRequest.zig");

const pane_resources = @import("../panes/pane_resources.zig");
const Tab = @import("../../workspace/Tab.zig");

const TabLocation = @import("telar-core").TabLocation;
pub const Outcome = enum { applied, ignored };
pub const Recovery = enum { coalesced, requested };

/// Commits correlated membership before releasing panes and repairing attachments. Example: `_ = try apply(client, snapshot);`
pub fn apply(client: *Client, snapshot: TabSnapshotViewType) !Outcome {
    const continuation = request_lifecycle.consume(client, snapshot.request_id) orelse
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
        request_lifecycle.ignorePane(client, pane_id);
        pane_resources.release(client, pane_id);
    }

    if (reconciliation.active) {
        const tab = client.model.workspace.find(reconciliation.location.tab_id) orelse return error.StaleTabReconciliation;
        try active_pane_resources.synchronize(client);
        try pane_geometry.offerAttached(client, &tab.model, reconciliation.area);
        try requestAttachments(client, tab, reconciliation.area);
    }

    return .applied;
}

/// Coalesces snapshot recovery until the pending response settles. Example: `_ = try recover(client, location);`
pub fn recover(client: *Client, location: TabLocation) !Recovery {
    if (request_lifecycle.has(client, .tab_snapshot)) {
        return .coalesced;
    }

    try request_lifecycle.requestTabSnapshot(client, location);
    return .requested;
}

/// Attaches newly visible detached panes once canonical membership is loaded. Example: `try attachActive(client, area);`
pub fn attachActive(client: *Client, area: RectType) !void {
    const active = client.model.workspace.active() orelse return;
    if (!active.snapshot_loaded) {
        return;
    }

    try requestAttachments(client, active, area);
}

fn requestAttachments(client: *Client, tab: *Tab, area: RectType) !void {
    var panes = tab.model.paneIterator();
    while (panes.next()) |pane| {
        if (pane.attached or request_lifecycle.hasPane(client, .attachment, pane.id)) {
            continue;
        }

        const size = tab.model.contentSize(pane.id, area) orelse continue;
        try requestAttachment(client, .{ .pane_id = pane.id, .location = tab.location, .size = size });
    }
}

fn requestAttachment(client: *Client, request: PaneAttachmentRequestType) !void {
    const request_id = try request_lifecycle.nextId(client);
    try request_lifecycle.deliver(client, .{
        .registration = .{
            .request_id = request_id,
            .continuation = .{ .attach_pane = .{
                .pane_id = request.pane_id,
                .location = request.location,
            } },
        },
        .message = .{ .open_pane = .{
            .request_id = request_id,
            .target = .{ .pane = request.pane_id },
            .size = request.size,
            .launch = null,
        } },
    });
}
