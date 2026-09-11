const ReleaseCapture = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("workspace_transition_delivery.zig");
const ReleaseEffects = @import("ReleaseEffects.zig");
model: *const client_model.Model,
events: [4]source_namespace.Event = undefined,
event_count: usize = 0,
bookmark: ?client_model.WorkspaceBookmark = null,
cleared_panes: [4]source_namespace.schema.PaneId = undefined,
cleared_count: usize = 0,
released_state_observed: bool = true,

pub fn effects(capture: *ReleaseCapture) ReleaseEffects {
    return .{
        .context = capture,
        .remember_bookmark = rememberBookmark,
        .clear_pane_graphics = clearPaneGraphics,
    };
}

fn rememberBookmark(raw_context: *anyopaque, bookmark: client_model.WorkspaceBookmark) void {
    const capture: *ReleaseCapture = @ptrCast(@alignCast(raw_context));
    capture.events[capture.event_count] = .remember_bookmark;
    capture.event_count += 1;
    capture.bookmark = bookmark;
}

fn clearPaneGraphics(raw_context: *anyopaque, pane_id: source_namespace.schema.PaneId) void {
    const capture: *ReleaseCapture = @ptrCast(@alignCast(raw_context));
    capture.events[capture.event_count] = .clear_pane_graphics;
    capture.event_count += 1;
    capture.cleared_panes[capture.cleared_count] = pane_id;
    capture.cleared_count += 1;
    capture.released_state_observed = capture.released_state_observed and
        !capture.model.panePasteActive() and capture.model.reportedPaneFocus() == null;
}

pub fn eventSlice(capture: *const ReleaseCapture) []const source_namespace.Event {
    return capture.events[0..capture.event_count];
}
