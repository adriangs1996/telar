const EffectsCapture = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("focus_pane.zig");
const FocusEffects = @import("FocusEffects.zig");
model: *const client_model.Model,
expected: source_namespace.schema.PaneId,
calls: usize = 0,
observed_commit: bool = false,
focus: ?client_model.PaneFocus = null,
area: ?source_namespace.ui.Rect = null,
fail: bool = false,

pub fn port(capture: *EffectsCapture) FocusEffects {
    return .{ .context = capture, .deliver = deliver };
}

fn deliver(context: *anyopaque, focus: client_model.PaneFocus, area: source_namespace.ui.Rect) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.focus = focus;
    capture.area = area;
    capture.observed_commit = capture.model.workspace.activeConst().?.model.layout.focused() == capture.expected and
        capture.model.version().panes == 1;

    if (capture.fail) {
        return error.FocusSyncFailed;
    }
}
