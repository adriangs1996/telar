const EffectsCapture = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("pane_graphics.zig");
const Effects = @import("PaneGraphicsEffects.zig");
model: *const client_model.Model,
result: source_namespace.ResourceResult,
events: [3]source_namespace.EffectEvent = undefined,
event_count: usize = 0,
applied_before_commit: bool = false,
fail_snapshot: bool = false,

pub fn port(capture: *EffectsCapture) Effects {
    return .{
        .context = capture,
        .apply = apply,
        .request_snapshot = requestSnapshot,
        .disable_shared = disableShared,
    };
}

fn record(capture: *EffectsCapture, event: source_namespace.EffectEvent) void {
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

fn apply(context: *anyopaque, command: source_namespace.Command) !source_namespace.ResourceResult {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    _ = command;
    capture.record(.apply);
    capture.applied_before_commit = capture.model.version().pane_graphics == 0;

    return capture.result;
}

fn requestSnapshot(context: *anyopaque, pane_id: source_namespace.schema.PaneId) !void {
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
