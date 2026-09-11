const ModelType = @import("../../model/Model.zig");
const PaneSplitCommitType = @import("../../model/PaneSplitCommit.zig");
const pane_split_confirmation_delivery = @import("pane_split_confirmation_delivery.zig");
const PaneSplitConfirmationDeliveryEffects = @import("PaneSplitConfirmationDeliveryEffects.zig");
const OfferEffectsType = @import("OfferEffects.zig");
const PaneResizeType = @import("telar-core").PaneResize;
const PaneIdType = @import("telar-core").PaneId;
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const EffectsCapture = @This();

model: *ModelType,
commit: PaneSplitCommitType,
snapshot_pending: bool = false,
events: [8]pane_split_confirmation_delivery.Event = undefined,
event_count: usize = 0,
committed_state_observed: bool = true,
failure: pane_split_confirmation_delivery.Failure = .none,

pub fn effects(capture: *EffectsCapture) PaneSplitConfirmationDeliveryEffects {
    return .{
        .context = capture,
        .detach_pane = detachPane,
        .set_pane_graphics_visible = setPaneGraphicsVisible,
        .synchronize_active_resources = synchronizeActiveResources,
        .workspace_snapshot_pending = workspaceSnapshotPending,
        .request_workspace_snapshot = requestWorkspaceSnapshot,
    };
}

pub fn geometryEffects(capture: *EffectsCapture) OfferEffectsType {
    return .{
        .context = capture,
        .deliver_resize = deliverResize,
    };
}

fn deliverResize(raw_context: *anyopaque, resize: PaneResizeType) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.{ .resize = resize.pane_id });
    if (capture.failure == .resize) {
        return error.PaneResizeFailed;
    }
}

fn synchronizeActiveResources(raw_context: *anyopaque) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.synchronize_active_resources);
    if (capture.failure == .active_resources) {
        return error.ActiveResourceSyncFailed;
    }
}

fn detachPane(raw_context: *anyopaque, pane_id: PaneIdType) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.{ .detach = pane_id });
    if (capture.failure == .detach) {
        return error.PaneDetachFailed;
    }
}

fn setPaneGraphicsVisible(raw_context: *anyopaque, pane_id: PaneIdType, visible: bool) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.{ .graphics_visibility = .{
        .pane_id = pane_id,
        .visible = visible,
    } });
    if (capture.failure == .graphics_visibility) {
        return error.GraphicsVisibilityFailed;
    }
}

fn workspaceSnapshotPending(raw_context: *anyopaque) bool {
    const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.workspace_snapshot_pending);

    return capture.snapshot_pending;
}

fn requestWorkspaceSnapshot(raw_context: *anyopaque, workspace: WorkspaceLocationType) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.{ .request_workspace_snapshot = workspace });
    if (capture.failure == .workspace_snapshot) {
        return error.WorkspaceSnapshotRequestFailed;
    }
}

fn append(capture: *EffectsCapture, event: pane_split_confirmation_delivery.Event) void {
    capture.observeCommit();
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

fn observeCommit(capture: *EffectsCapture) void {
    const version = capture.model.version();
    capture.committed_state_observed = capture.committed_state_observed and
        version.workspace == capture.commit.workspace_revision and
        version.tabs == capture.commit.tabs_revision and
        version.active_tab == capture.commit.active_tab_revision and
        version.panes == capture.commit.panes_revision;

    switch (capture.commit.disposition) {
        .active, .inactive => {
            const tab = capture.model.workspace.find(capture.commit.location.tab_id) orelse {
                capture.committed_state_observed = false;
                return;
            };
            const pane = tab.model.find(capture.commit.pane_id) orelse {
                capture.committed_state_observed = false;
                return;
            };
            capture.committed_state_observed = capture.committed_state_observed and
                pane.attached == (capture.commit.disposition == .active) and
                tab.model.layout.currentRevision() == capture.commit.layout_revision;
        },
        .stale => {
            capture.committed_state_observed = capture.committed_state_observed and
                capture.model.workspace.findPane(capture.commit.pane_id) == null;
        },
    }
}

pub fn eventSlice(capture: *const EffectsCapture) []const pane_split_confirmation_delivery.Event {
    return capture.events[0..capture.event_count];
}
