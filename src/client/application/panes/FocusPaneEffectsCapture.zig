const ModelType = @import("../../model/Model.zig");
const PaneIdType = @import("telar-core").PaneId;
const PaneFocusType = @import("../../model/PaneFocus.zig");
const RectType = @import("telar-core").Rect;
const FocusEffects = @import("FocusEffects.zig");
const EffectsCapture = @This();

model: *const ModelType,
expected: PaneIdType,
calls: usize = 0,
observed_commit: bool = false,
focus: ?PaneFocusType = null,
area: ?RectType = null,
fail: bool = false,

pub fn port(capture: *EffectsCapture) FocusEffects {
    return .{ .context = capture, .deliver = deliver };
}

fn deliver(context: *anyopaque, focus: PaneFocusType, area: RectType) !void {
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
