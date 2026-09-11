const ModelType = @import("../../model/Model.zig");
const PaneViewportChangeType = @import("../../model/PaneViewportChange.zig");
const PaneViewportEffects = @import("PaneViewportEffects.zig");
const EffectsCapture = @This();

model: *const ModelType,
calls: usize = 0,
observed_commit: bool = false,
change: ?PaneViewportChangeType = null,
fail: bool = false,

pub fn port(capture: *EffectsCapture) PaneViewportEffects {
    return .{ .context = capture, .sync = sync };
}

fn sync(context: *anyopaque, change: PaneViewportChangeType) !void {
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
