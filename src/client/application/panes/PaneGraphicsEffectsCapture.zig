const ModelType = @import("../../model/Model.zig");
const pane_graphics_ops = @import("pane_graphics.zig");
const PaneGraphicsEffects = @import("PaneGraphicsEffects.zig");
const PaneIdType = @import("telar-core").PaneId;
const EffectsCapture = @This();

model: *const ModelType,
result: pane_graphics_ops.ResourceResult,
events: [3]pane_graphics_ops.EffectEvent = undefined,
event_count: usize = 0,
applied_before_commit: bool = false,
fail_snapshot: bool = false,

pub fn port(capture: *EffectsCapture) PaneGraphicsEffects {
    return .{
        .context = capture,
        .apply = apply,
        .request_snapshot = requestSnapshot,
        .disable_shared = disableShared,
    };
}

fn record(capture: *EffectsCapture, event: pane_graphics_ops.EffectEvent) void {
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

fn apply(context: *anyopaque, command: pane_graphics_ops.Command) !pane_graphics_ops.ResourceResult {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    _ = command;
    capture.record(.apply);
    capture.applied_before_commit = capture.model.version().pane_graphics == 0;

    return capture.result;
}

fn requestSnapshot(context: *anyopaque, pane_id: PaneIdType) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    _ = pane_id;
    capture.record(.request_snapshot);

    if (capture.fail_snapshot) {
        return error.SnapshotRequestFailed;
    }
}

fn disableShared(context: *anyopaque) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.record(.disable_shared);
}
