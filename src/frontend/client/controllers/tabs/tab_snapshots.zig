//! Client resource reconciliation after canonical tab snapshots.

const std = @import("std");
const core = @import("telar-core");
const tabs_application = @import("../../application/tabs/root.zig");
const panes_application = @import("../../application/panes/root.zig");
const client_model = @import("../../model/root.zig");
const active_pane_resources = @import("../panes/active_pane_resources.zig");
const pane_geometry = @import("../panes/pane_geometry.zig");
const request_lifecycle = @import("../../connection/request_lifecycle.zig");

const Client = @import("../../client.zig");
const pane_attachment_requests = panes_application.pane_attachment_requests;
const schema = core.schema;
const tab_snapshot = tabs_application.tab_snapshot;
const tab_snapshot_delivery = tabs_application.tab_snapshot_delivery;
const ui = core.ui;

pub const Outcome = enum {
    applied,
    ignored,
};

/// Consumes one correlated response and applies its canonical pane membership.
///
/// ```zig
/// _ = try apply(client, snapshot);
/// ```
pub fn apply(client: *Client, snapshot: schema.TabSnapshotView) !Outcome {
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

    var pane_ids: [schema.max_panes_per_tab]schema.PaneId = undefined;
    var pane_count: usize = 0;
    var panes = snapshot.panes();
    while (try panes.next()) |pane| {
        if (pane_count == pane_ids.len) {
            return error.TooManyPanes;
        }

        pane_ids[pane_count] = pane.pane_id;
        pane_count += 1;
    }

    if (client.saved_layouts.find(snapshot.location)) |saved| {
        if (!client.model.workspace.restoreClientLayoutOnNextSnapshot(snapshot.location, saved.layout)) {
            return error.UnexpectedTabSnapshot;
        }
    }

    var use_case = reconciliationHandler(client);
    try use_case.execute(.{
        .location = snapshot.location,
        .panes = pane_ids[0..pane_count],
    });
    client.saved_layouts.forget(snapshot.location);

    return .applied;
}

/// Requests an attachment for every detached active pane that has visible
/// content in `area`, so a pane skipped by a crowded layout attaches once the
/// geometry gives it room.
///
/// ```zig
/// try attachActive(client, client.view.workbench());
/// ```
pub fn attachActive(client: *Client, area: ui.Rect) !void {
    var use_case: pane_attachment_requests.RequestActivePaneAttachmentsHandler = .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .attachment_pending = attachmentPending,
            .request_attachment = requestAttachment,
        },
    };

    _ = try use_case.execute(area);
}

fn reconciliationHandler(client: *Client) tab_snapshot.ApplyTabSnapshotHandler {
    return .{
        .model = &client.model,
        .area = client.view.workbench(),
        .effects = .{
            .context = client,
            .deliver = deliverReconciliation,
        },
    };
}

fn deliverReconciliation(context: *anyopaque, reconciliation: *const client_model.TabReconciliation) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    var use_case: tab_snapshot_delivery.DeliverTabSnapshotHandler = .{
        .model = &client.model,
        .geometry_effects = pane_geometry.offerEffects(client),
        .effects = .{
            .context = client,
            .ignore_pane_requests = ignorePaneRequests,
            .clear_pane_graphics = clearPaneGraphics,
            .synchronize_active_resources = synchronizeActiveResources,
            .attachment_pending = attachmentPending,
            .request_attachment = requestAttachment,
        },
    };

    try use_case.execute(reconciliation);
}

fn ignorePaneRequests(context: *anyopaque, pane_id: schema.PaneId) void {
    const client: *Client = @ptrCast(@alignCast(context));

    request_lifecycle.ignorePane(client, pane_id);
}

fn clearPaneGraphics(context: *anyopaque, pane_id: schema.PaneId) void {
    const client: *Client = @ptrCast(@alignCast(context));

    client.graphics_store.clearPane(pane_id);
}

fn synchronizeActiveResources(context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try active_pane_resources.synchronize(client);
}

fn attachmentPending(context: *anyopaque, pane_id: schema.PaneId) bool {
    const client: *Client = @ptrCast(@alignCast(context));

    return request_lifecycle.hasPane(client, .attachment, pane_id);
}

fn requestAttachment(context: *anyopaque, request: tab_snapshot_delivery.PaneAttachmentRequest) !void {
    const client: *Client = @ptrCast(@alignCast(context));
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
