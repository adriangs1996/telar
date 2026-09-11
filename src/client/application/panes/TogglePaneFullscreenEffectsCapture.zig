const ModelType = @import("../../model/Model.zig");
const PaneIdType = @import("telar-core").PaneId;
const PaneGeometryChangeType = @import("../../model/PaneGeometryChange.zig");
const FullscreenEffects = @import("FullscreenEffects.zig");
const EffectsCapture = @This();

model: *const ModelType,
expected_focused: PaneIdType,
calls: usize = 0,
observed_commit: bool = false,
change: ?PaneGeometryChangeType = null,
fail: bool = false,

pub fn port(capture: *EffectsCapture) FullscreenEffects {
    return .{ .context = capture, .deliver = deliver };
}

fn deliver(context: *anyopaque, change: PaneGeometryChangeType) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    const active = capture.model.workspace.activeConst().?;
    capture.calls += 1;
    capture.change = change;
    capture.observed_commit = active.model.layout.focused() == capture.expected_focused and
        active.model.layout.isFullscreen() == change.fullscreen and
        capture.model.version().panes == change.panes_revision and
        capture.model.version().panes == 1;

    if (capture.fail) {
        return error.FullscreenSyncFailed;
    }
}
