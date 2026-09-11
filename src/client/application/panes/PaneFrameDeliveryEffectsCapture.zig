const ModelType = @import("../../model/Model.zig");
const PaneFrameCommitType = @import("../../model/PaneFrameCommit.zig");
const pane_frame_delivery = @import("pane_frame_delivery.zig");
const PaneIdType = @import("telar-core").PaneId;
const PaneFrameDeliveryEffects = @import("PaneFrameDeliveryEffects.zig");
const std = @import("std");
const EffectsCapture = @This();

model: *const ModelType,
commit: PaneFrameCommitType,
current_visibility: bool,
events: [3]pane_frame_delivery.Event = undefined,
event_count: usize = 0,
observed_pane: ?PaneIdType = null,
delivered_visibility: ?bool = null,
committed_state_observed: bool = true,
failure: pane_frame_delivery.Failure = .none,

pub fn effects(capture: *EffectsCapture) PaneFrameDeliveryEffects {
    return .{
        .context = capture,
        .pane_graphics_visible = paneGraphicsVisible,
        .set_pane_graphics_visible = setPaneGraphicsVisible,
        .synchronize_active_resources = synchronizeActiveResources,
    };
}

fn paneGraphicsVisible(raw_context: *anyopaque, pane_id: PaneIdType) bool {
    const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.read_graphics_visibility);
    capture.observed_pane = pane_id;

    return capture.current_visibility;
}

fn setPaneGraphicsVisible(raw_context: *anyopaque, pane_id: PaneIdType, visible: bool) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.set_graphics_visibility);
    capture.observed_pane = pane_id;
    capture.delivered_visibility = visible;
    if (capture.failure == .graphics_visibility) {
        return error.GraphicsVisibilityFailed;
    }

    capture.current_visibility = visible;
}

fn synchronizeActiveResources(raw_context: *anyopaque) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(raw_context));
    capture.append(.synchronize_active_resources);
    if (capture.failure == .active_resources) {
        return error.ActiveResourceSyncFailed;
    }
}

fn append(capture: *EffectsCapture, event: pane_frame_delivery.Event) void {
    capture.observeCommit();
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

fn observeCommit(capture: *EffectsCapture) void {
    const tab = capture.model.workspace.tabForPaneConst(capture.commit.pane_id) orelse {
        capture.committed_state_observed = false;
        return;
    };
    const pane = tab.model.findConst(capture.commit.pane_id) orelse {
        capture.committed_state_observed = false;
        return;
    };
    const version = capture.model.version();

    capture.committed_state_observed = capture.committed_state_observed and
        std.meta.eql(tab.location, capture.commit.location) and
        pane.applied_frame_id == capture.commit.frame_id and
        version.workspace == capture.commit.workspace_revision and
        version.tabs == capture.commit.tabs_revision and
        version.active_tab == capture.commit.active_tab_revision and
        version.panes == capture.commit.panes_revision and
        version.frame == capture.commit.frame_revision;
}

pub fn eventSlice(capture: *const EffectsCapture) []const pane_frame_delivery.Event {
    return capture.events[0..capture.event_count];
}
