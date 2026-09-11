const EffectsCapture = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("toggle_pane_fullscreen.zig");
const FullscreenEffects = @import("FullscreenEffects.zig");
model: *const client_model.Model,
expected_focused: source_namespace.schema.PaneId,
calls: usize = 0,
observed_commit: bool = false,
change: ?client_model.PaneGeometryChange = null,
fail: bool = false,

pub fn port(capture: *EffectsCapture) FullscreenEffects {
    return .{ .context = capture, .deliver = deliver };
}

fn deliver(context: *anyopaque, change: client_model.PaneGeometryChange) !void {
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
