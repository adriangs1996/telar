const ModelType = @import("../../model/Model.zig");
const WorkspaceReconciliationType = @import("../../model/WorkspaceReconciliation.zig");
const workspace_snapshot_delivery = @import("workspace_snapshot_delivery.zig");
const PaneResizeType = @import("telar-core").PaneResize;
const WorkspaceSnapshotDeliveryEffects = @import("WorkspaceSnapshotDeliveryEffects.zig");
const OfferEffectsType = @import("../panes/OfferEffects.zig");
const TabIdType = @import("telar-core").TabId;
const PaneIdType = @import("telar-core").PaneId;
const TabLocationType = @import("telar-core").TabLocation;
const std = @import("std");
const EffectsCapture = @This();

model: *ModelType,
reconciliation: *const WorkspaceReconciliationType,
events: [10]workspace_snapshot_delivery.Event = undefined,
event_count: usize = 0,
pending_snapshot: bool = false,
delivered_resize: ?PaneResizeType = null,
committed_state_observed: bool = true,
resources_released_before_graphics: bool = true,
failure: workspace_snapshot_delivery.Failure = .none,

pub fn effects(capture: *EffectsCapture) WorkspaceSnapshotDeliveryEffects {
    return .{
        .context = capture,
        .ignore_tab_requests = ignoreTabRequests,
        .clear_pane_graphics = clearPaneGraphics,
        .set_pane_graphics_visible = setPaneGraphicsVisible,
        .synchronize_active_resources = synchronizeActiveResources,
        .tab_snapshot_pending = tabSnapshotPending,
        .request_tab_snapshot = requestTabSnapshot,
    };
}

pub fn geometryEffects(capture: *EffectsCapture) OfferEffectsType {
    return .{
        .context = capture,
        .deliver_resize = deliverResize,
    };
}

fn ignoreTabRequests(raw_context: *anyopaque, tab_id: TabIdType) void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.{ .ignore_tab = tab_id });
}

fn clearPaneGraphics(raw_context: *anyopaque, pane_id: PaneIdType) void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.{ .clear_graphics = pane_id });
    capture.resources_released_before_graphics = capture.resources_released_before_graphics and
        !capture.model.panePasteActive() and capture.model.reportedPaneFocus() == null;
}

fn setPaneGraphicsVisible(raw_context: *anyopaque, pane_id: PaneIdType, visible: bool) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.{ .set_graphics_visible = .{
        .pane_id = pane_id,
        .visible = visible,
    } });
    if (capture.failure == .graphics_visibility) {
        return error.GraphicsVisibilityFailed;
    }
}

fn synchronizeActiveResources(raw_context: *anyopaque) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.synchronize_active_resources);
    if (capture.failure == .active_resources) {
        return error.ActiveResourceSyncFailed;
    }
}

fn tabSnapshotPending(raw_context: *anyopaque) bool {
    const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.tab_snapshot_pending);

    return capture.pending_snapshot;
}

fn requestTabSnapshot(raw_context: *anyopaque, location: TabLocationType) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.{ .request_tab_snapshot = location });
    if (capture.failure == .tab_snapshot) {
        return error.TabSnapshotRequestFailed;
    }
}

fn deliverResize(raw_context: *anyopaque, resize: PaneResizeType) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.{ .resize = resize.pane_id });
    capture.delivered_resize = resize;
    if (capture.failure == .resize) {
        return error.PaneResizeFailed;
    }
}

fn append(capture: *EffectsCapture, event: workspace_snapshot_delivery.Event) void {
    capture.observeCommit();
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

fn observeCommit(capture: *EffectsCapture) void {
    const active = capture.model.workspace.activeConst() orelse {
        capture.committed_state_observed = false;
        return;
    };
    const version = capture.model.version();

    capture.committed_state_observed = capture.committed_state_observed and
        std.meta.eql(active.location, capture.reconciliation.active) and
        active.snapshot_loaded == capture.reconciliation.active_snapshot_loaded and
        version.workspace == capture.reconciliation.workspace_revision and
        version.tabs == capture.reconciliation.tabs_revision and
        version.active_tab == capture.reconciliation.active_tab_revision and
        version.panes == capture.reconciliation.panes_revision;
}

pub fn eventSlice(capture: *const EffectsCapture) []const workspace_snapshot_delivery.Event {
    return capture.events[0..capture.event_count];
}
