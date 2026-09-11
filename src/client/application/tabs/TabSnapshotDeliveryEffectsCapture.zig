const EffectsCapture = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("tab_snapshot_delivery.zig");
const Effects = @import("TabSnapshotDeliveryEffects.zig");
const pane_geometry_delivery = @import("../panes/root.zig").pane_geometry_delivery;
const std = @import("std");
model: *client_model.Model,
reconciliation: *const client_model.TabReconciliation,
pending_attachment: ?source_namespace.schema.PaneId = null,
events: [10]source_namespace.Event = undefined,
event_count: usize = 0,
attachment: ?source_namespace.PaneAttachmentRequest = null,
committed_state_observed: bool = true,
resources_released_before_graphics: bool = true,
failure: source_namespace.Failure = .none,

pub fn effects(capture: *EffectsCapture) Effects {
    return .{
        .context = capture,
        .ignore_pane_requests = ignorePaneRequests,
        .clear_pane_graphics = clearPaneGraphics,
        .synchronize_active_resources = synchronizeActiveResources,
        .attachment_pending = attachmentPending,
        .request_attachment = requestAttachment,
    };
}

pub fn geometryEffects(capture: *EffectsCapture) pane_geometry_delivery.OfferEffects {
    return .{
        .context = capture,
        .deliver_resize = deliverResize,
    };
}

fn ignorePaneRequests(raw_context: *anyopaque, pane_id: source_namespace.schema.PaneId) void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.{ .ignore_pane = pane_id });
}

fn clearPaneGraphics(raw_context: *anyopaque, pane_id: source_namespace.schema.PaneId) void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.{ .clear_graphics = pane_id });
    capture.resources_released_before_graphics = capture.resources_released_before_graphics and
        !capture.model.panePasteActive() and capture.model.reportedPaneFocus() == null;
}

fn synchronizeActiveResources(raw_context: *anyopaque) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.synchronize_active_resources);
    if (capture.failure == .active_resources) {
        return error.ActiveResourceSyncFailed;
    }
}

fn deliverResize(raw_context: *anyopaque, resize: source_namespace.schema.PaneResize) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.{ .resize = resize.pane_id });
    if (capture.failure == .resize) {
        return error.PaneResizeFailed;
    }
}

fn attachmentPending(raw_context: *anyopaque, pane_id: source_namespace.schema.PaneId) bool {
    const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.{ .attachment_pending = pane_id });

    return capture.pending_attachment == pane_id;
}

fn requestAttachment(raw_context: *anyopaque, request: source_namespace.PaneAttachmentRequest) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.{ .request_attachment = request.pane_id });
    capture.attachment = request;
    if (capture.failure == .attachment) {
        return error.AttachmentRequestFailed;
    }
}

fn append(capture: *EffectsCapture, event: source_namespace.Event) void {
    capture.observeCommit();
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

fn observeCommit(capture: *EffectsCapture) void {
    const tab = capture.model.workspace.find(capture.reconciliation.location.tab_id) orelse {
        capture.committed_state_observed = false;
        return;
    };
    const active = capture.model.workspace.activeConst() orelse {
        capture.committed_state_observed = false;
        return;
    };
    const version = capture.model.version();

    capture.committed_state_observed = capture.committed_state_observed and
        std.meta.eql(tab.location, capture.reconciliation.location) and
        capture.reconciliation.active == std.meta.eql(active.location, tab.location) and
        tab.snapshot_loaded == capture.reconciliation.snapshot_loaded and
        tab.model.layout.currentRevision() == capture.reconciliation.layout_revision and
        version.workspace == capture.reconciliation.workspace_revision and
        version.tabs == capture.reconciliation.tabs_revision and
        version.active_tab == capture.reconciliation.active_tab_revision and
        version.panes == capture.reconciliation.panes_revision;
}

pub fn eventSlice(capture: *const EffectsCapture) []const source_namespace.Event {
    return capture.events[0..capture.event_count];
}
