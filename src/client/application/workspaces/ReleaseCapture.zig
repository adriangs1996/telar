const ModelType = @import("../../model/Model.zig");
const workspace_transition_delivery = @import("workspace_transition_delivery.zig");
const WorkspaceBookmarkType = @import("../../model/WorkspaceBookmark.zig");
const PaneIdType = @import("telar-core").PaneId;
const ReleaseEffects = @import("ReleaseEffects.zig");
const ReleaseCapture = @This();

model: *const ModelType,
events: [4]workspace_transition_delivery.Event = undefined,
event_count: usize = 0,
bookmark: ?WorkspaceBookmarkType = null,
cleared_panes: [4]PaneIdType = undefined,
cleared_count: usize = 0,
released_state_observed: bool = true,

pub fn effects(capture: *ReleaseCapture) ReleaseEffects {
    return .{
        .context = capture,
        .remember_bookmark = rememberBookmark,
        .clear_pane_graphics = clearPaneGraphics,
    };
}

fn rememberBookmark(raw_context: *anyopaque, bookmark: WorkspaceBookmarkType) void {
    const capture: *ReleaseCapture = @ptrCast(@alignCast(raw_context));
    capture.events[capture.event_count] = .remember_bookmark;
    capture.event_count += 1;
    capture.bookmark = bookmark;
}

fn clearPaneGraphics(raw_context: *anyopaque, pane_id: PaneIdType) void {
    const capture: *ReleaseCapture = @ptrCast(@alignCast(raw_context));
    capture.events[capture.event_count] = .clear_pane_graphics;
    capture.event_count += 1;
    capture.cleared_panes[capture.cleared_count] = pane_id;
    capture.cleared_count += 1;
    capture.released_state_observed = capture.released_state_observed and
        !capture.model.panePasteActive() and capture.model.reportedPaneFocus() == null;
}

pub fn eventSlice(capture: *const ReleaseCapture) []const workspace_transition_delivery.Event {
    return capture.events[0..capture.event_count];
}
