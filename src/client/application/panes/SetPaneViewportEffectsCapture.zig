const EffectsCapture = @This();
const client_model = @import("../../root.zig").model;
const PaneViewportEffects = @import("PaneViewportEffects.zig");
model: *const client_model.Model,
calls: usize = 0,
observed_commit: bool = false,
change: ?client_model.PaneViewportChange = null,
fail: bool = false,

pub fn port(capture: *EffectsCapture) PaneViewportEffects {
    return .{ .context = capture, .sync = sync };
}

fn sync(context: *anyopaque, change: client_model.PaneViewportChange) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    const pane = capture.model.workspace.activeConst().?.model.findConst(change.pane_id).?;
    capture.calls += 1;
    capture.change = change;
    capture.observed_commit = pane.scroll.offset == change.offset and
        capture.model.version().viewport == change.viewport_revision;

    if (capture.fail) {
        return error.ViewportSyncFailed;
    }
}
