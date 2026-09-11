//! Client resource reconciliation after canonical tab snapshots.

const Client = @import("../../Client.zig");
const TabSnapshotViewType = @import("telar-core").TabSnapshotView;
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const std = @import("std");
const max_panes_per_tab_module = @import("telar-core").max_panes_per_tab;
const PaneIdType = @import("telar-core").PaneId;
const RectType = @import("telar-core").Rect;
const RequestActivePaneAttachmentsHandlerType = @import("telar-client").RequestActivePaneAttachmentsHandler;
const ApplyTabSnapshotHandlerType = @import("telar-client").ApplyTabSnapshotHandler;
const TabReconciliationType = @import("telar-client").TabReconciliation;
const DeliverTabSnapshotHandlerType = @import("telar-client").DeliverTabSnapshotHandler;
const pane_geometry = @import("../panes/pane_geometry.zig");
const active_pane_resources = @import("../panes/active_pane_resources.zig");
const PaneAttachmentRequestType = @import("telar-client").PaneAttachmentRequest;

pub const Outcome = enum {
    applied,
    ignored,
};

/// Consumes one correlated response and applies its canonical pane membership.
///
/// ```zig
/// _ = try apply(client, snapshot);
/// ```
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

    var use_case = reconciliationHandler(client);
    try use_case.execute(.{
        .location = snapshot.location,
        .panes = pane_ids[0..pane_count],
    });

    return .applied;
}

/// Requests an attachment for every detached active pane that has visible
/// content in `area`, so a pane skipped by a crowded layout attaches once the
/// geometry gives it room.
///
/// ```zig
/// try attachActive(client, client.geometry().area);
/// ```
pub fn attachActive(client: *Client, area: RectType) !void {
    var use_case: RequestActivePaneAttachmentsHandlerType = .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .attachment_pending = attachmentPending,
            .request_attachment = requestAttachment,
        },
    };

    _ = try use_case.execute(area);
}

fn reconciliationHandler(client: *Client) ApplyTabSnapshotHandlerType {
    return .{
        .model = &client.model,
        .area = client.geometry().area,
        .effects = .{
            .context = client,
            .deliver = deliverReconciliation,
        },
    };
}

fn deliverReconciliation(context: *anyopaque, reconciliation: *const TabReconciliationType) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    var use_case: DeliverTabSnapshotHandlerType = .{
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

fn ignorePaneRequests(context: *anyopaque, pane_id: PaneIdType) void {
    const client: *Client = @ptrCast(@alignCast(context));

    request_lifecycle.ignorePane(client, pane_id);
}

fn clearPaneGraphics(context: *anyopaque, pane_id: PaneIdType) void {
    const client: *Client = @ptrCast(@alignCast(context));

    client.graphics_store.clearPane(pane_id);
}

fn synchronizeActiveResources(context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try active_pane_resources.synchronize(client);
}

fn attachmentPending(context: *anyopaque, pane_id: PaneIdType) bool {
    const client: *Client = @ptrCast(@alignCast(context));

    return request_lifecycle.hasPane(client, .attachment, pane_id);
}

fn requestAttachment(context: *anyopaque, request: PaneAttachmentRequestType) !void {
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
