const ModelType = @import("../../model/Model.zig");
const PaneIdType = @import("telar-core").PaneId;
const PaneResourceReleaseEffects = @import("PaneResourceReleaseEffects.zig");
const EffectCapture = @This();

model: ?*const ModelType = null,
calls: usize = 0,
pane_id: ?PaneIdType = null,
observed_released: bool = false,

pub fn effects(capture: *EffectCapture) PaneResourceReleaseEffects {
    return .{ .context = capture, .clear_graphics = clearGraphics };
}

fn clearGraphics(context: *anyopaque, pane_id: PaneIdType) void {
    const capture: *EffectCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.pane_id = pane_id;

    if (capture.model) |model| {
        capture.observed_released = !model.copyModeActive() and
            !model.panePasteActive() and model.reportedPaneFocus() == null;
    }
}
