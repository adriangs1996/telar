const EffectCapture = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("pane_resource_release.zig");
const Effects = @import("PaneResourceReleaseEffects.zig");
model: ?*const client_model.Model = null,
calls: usize = 0,
pane_id: ?source_namespace.schema.PaneId = null,
observed_released: bool = false,

pub fn effects(capture: *EffectCapture) Effects {
    return .{ .context = capture, .clear_graphics = clearGraphics };
}

fn clearGraphics(context: *anyopaque, pane_id: source_namespace.schema.PaneId) void {
    const capture: *EffectCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.pane_id = pane_id;

    if (capture.model) |model| {
        capture.observed_released = !model.copyModeActive() and
            !model.panePasteActive() and model.reportedPaneFocus() == null;
    }
}
