const ModelType = @import("../../model/Model.zig");
const types = @import("../../model/types.zig");
const tab_removal_delivery = @import("tab_removal_delivery.zig");
const TabRemovalDeliveryEffects = @import("TabRemovalDeliveryEffects.zig");
const TabLocationType = @import("telar-core").TabLocation;
const PaneIdType = @import("telar-core").PaneId;
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const WorkspaceIdType = @import("telar-core").WorkspaceId;
const std = @import("std");
const EffectsCapture = @This();

model: *ModelType,
commit: types.TabRemovalCommit,
events: [16]tab_removal_delivery.Event = undefined,
event_count: usize = 0,
snapshot_pending: bool = false,
committed_state_observed: bool = true,
pane_authorities_released: bool = true,
focus_retired_before_activation: bool = true,
failure: tab_removal_delivery.Failure = .none,

pub fn effects(capture: *EffectsCapture) TabRemovalDeliveryEffects {
    return .{
        .context = capture,
        .retire_tab_requests = retireTabRequests,
        .clear_pane_graphics = clearPaneGraphics,
        .set_pane_graphics_visible = setPaneGraphicsVisible,
        .synchronize_active_resources = synchronizeActiveResources,
        .tab_snapshot_pending = tabSnapshotPending,
        .request_tab_snapshot = requestTabSnapshot,
        .forget_workspace = forgetWorkspace,
        .request_workspace = requestWorkspace,
    };
}

fn retireTabRequests(context: *anyopaque, location: TabLocationType) void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.{ .retire_tab_requests = location });
}

fn clearPaneGraphics(context: *anyopaque, pane_id: PaneIdType) void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.{ .clear_graphics = pane_id });
    if (capture.model.panePasteSession()) |session| {
        capture.pane_authorities_released = capture.pane_authorities_released and session.pane_id != pane_id;
    }
    if (capture.model.reportedPaneFocus()) |reported| {
        capture.pane_authorities_released = capture.pane_authorities_released and reported.pane_id != pane_id;
    }
}

fn setPaneGraphicsVisible(context: *anyopaque, pane_id: PaneIdType, visible: bool) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.{ .graphics_visibility = .{
        .pane_id = pane_id,
        .visible = visible,
    } });
    capture.focus_retired_before_activation = capture.focus_retired_before_activation and
        capture.model.reportedPaneFocus() == null;
    if (capture.failure == .graphics_visibility) {
        return error.GraphicsVisibilityFailed;
    }
}

fn synchronizeActiveResources(context: *anyopaque) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.synchronize_active_resources);
    capture.focus_retired_before_activation = capture.focus_retired_before_activation and
        capture.model.reportedPaneFocus() == null;
    if (capture.failure == .active_resources) {
        return error.ActiveResourceSynchronizationFailed;
    }
}

fn tabSnapshotPending(context: *anyopaque) bool {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.tab_snapshot_pending);

    return capture.snapshot_pending;
}

fn requestTabSnapshot(context: *anyopaque, location: TabLocationType) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.{ .request_tab_snapshot = location });
    if (capture.failure == .tab_snapshot) {
        return error.TabSnapshotRequestFailed;
    }
}

fn forgetWorkspace(context: *anyopaque, workspace: WorkspaceLocationType) void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.{ .forget_workspace = workspace });
}

fn requestWorkspace(context: *anyopaque, workspace: WorkspaceIdType) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.append(.{ .request_workspace = workspace });
    if (capture.failure == .workspace_handoff) {
        return error.WorkspaceHandoffFailed;
    }
}

fn append(capture: *EffectsCapture, event: tab_removal_delivery.Event) void {
    capture.committed_state_observed = capture.committed_state_observed and capture.observesCommit();
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

fn observesCommit(capture: *const EffectsCapture) bool {
    const version = capture.model.version();
    return switch (capture.commit) {
        .stale => |stale| version.workspace == stale.workspace_revision and
            version.tabs == stale.tabs_revision and
            version.active_tab == stale.active_tab_revision and
            version.panes == stale.panes_revision and
            version.copy == stale.copy_revision,
        .removed => |removal| observed: {
            if (capture.model.workspace.find(removal.removed.tab_id) != null or
                version.workspace != removal.workspace_revision or
                version.tabs != removal.tabs_revision or
                version.active_tab != removal.active_tab_revision or
                version.panes != removal.panes_revision or
                version.copy != removal.copy_revision)
            {
                break :observed false;
            }

            if (removal.active) |location| {
                const active = capture.model.workspace.find(location.tab_id) orelse break :observed false;
                break :observed std.meta.eql(active.location, location) and
                    active.model.layout.currentRevision() == removal.active_layout_revision;
            }

            break :observed capture.model.workspace.workspace == null and removal.active_layout_revision == 0;
        },
    };
}

pub fn eventSlice(capture: *const EffectsCapture) []const tab_removal_delivery.Event {
    return capture.events[0..capture.event_count];
}
