const ModelType = @import("../../model/Model.zig");
const PaneIdType = @import("telar-core").PaneId;
const PaneGeometryChangeType = @import("../../model/PaneGeometryChange.zig");
const ResizeEffects = @import("ResizeEffects.zig");
const EffectsCapture = @This();

model: *ModelType,
expected_focused: PaneIdType,
width_before: u16,
calls: usize = 0,
observed_commit: bool = false,
resize: ?PaneGeometryChangeType = null,
fail: bool = false,

pub fn port(capture: *EffectsCapture) ResizeEffects {
    return .{ .context = capture, .deliver = deliver };
}

fn deliver(context: *anyopaque, resize: PaneGeometryChangeType) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    const active = capture.model.workspace.active().?;
    capture.calls += 1;
    capture.resize = resize;
    capture.observed_commit = active.model.layout.focused() == capture.expected_focused and
        capture.model.version().panes == resize.panes_revision and
        active.model.contentSize(capture.expected_focused, resize.area).?.cols > capture.width_before and
        capture.model.version().panes == 1;

    if (capture.fail) {
        return error.ResizeSyncFailed;
    }
}
