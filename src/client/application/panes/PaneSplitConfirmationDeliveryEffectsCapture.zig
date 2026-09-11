const EffectsCapture = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("pane_split_confirmation_delivery.zig");
const Effects = @import("PaneSplitConfirmationDeliveryEffects.zig");
const pane_geometry_delivery = @import("pane_geometry_delivery.zig");
model: *client_model.Model,
commit: client_model.PaneSplitCommit,
snapshot_pending: bool = false,
events: [8]source_namespace.Event = undefined,
event_count: usize = 0,
committed_state_observed: bool = true,
failure: source_namespace.Failure = .none,

pub fn effects(capture: *EffectsCapture) Effects {
    return .{
        .context = capture,
        .detach_pane = detachPane,
        .set_pane_graphics_visible = setPaneGraphicsVisible,
        .synchronize_active_resources = synchronizeActiveResources,
        .workspace_snapshot_pending = workspaceSnapshotPending,
        .request_workspace_snapshot = requestWorkspaceSnapshot,
    };
}

pub fn geometryEffects(capture: *EffectsCapture) pane_geometry_delivery.OfferEffects {
    return .{
        .context = capture,
        .deliver_resize = deliverResize,
    };
}

fn deliverResize(raw_context: *anyopaque, resize: source_namespace.schema.PaneResize) !void {
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

fn detachPane(raw_context: *anyopaque, pane_id: source_namespace.schema.PaneId) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.{ .detach = pane_id });
    if (capture.failure == .detach) {
        return error.PaneDetachFailed;
    }
}

fn setPaneGraphicsVisible(raw_context: *anyopaque, pane_id: source_namespace.schema.PaneId, visible: bool) !void {
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

fn requestWorkspaceSnapshot(raw_context: *anyopaque, workspace: source_namespace.schema.WorkspaceLocation) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.{ .request_workspace_snapshot = workspace });
    if (capture.failure == .workspace_snapshot) {
        return error.WorkspaceSnapshotRequestFailed;
    }
}

fn append(capture: *EffectsCapture, event: source_namespace.Event) void {
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

pub fn eventSlice(capture: *const EffectsCapture) []const source_namespace.Event {
    return capture.events[0..capture.event_count];
}
