const EffectsCapture = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("pane_frame.zig");
const PaneFrameEffects = @import("PaneFrameEffects.zig");
model: *client_model.Model,
events: [1]source_namespace.EffectEvent = undefined,
event_count: usize = 0,
recovery: ?client_model.PaneFrameRecovery = null,
commit: ?client_model.PaneFrameCommit = null,
observed_commit: bool = false,
fail_recovery: bool = false,
fail_delivery: bool = false,

pub fn port(capture: *EffectsCapture) PaneFrameEffects {
    return .{
        .context = capture,
        .recover = recover,
        .deliver = deliver,
    };
}

fn record(capture: *EffectsCapture, event: source_namespace.EffectEvent) void {
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

fn recover(context: *anyopaque, recovery: client_model.PaneFrameRecovery) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.record(.recover);
    capture.recovery = recovery;

    if (capture.fail_recovery) {
        return error.RecoveryFailed;
    }
}

fn deliver(context: *anyopaque, commit: client_model.PaneFrameCommit) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    const pane = capture.model.workspace.findPane(commit.pane_id).?;
    capture.record(.deliver);
    capture.commit = commit;
    capture.observed_commit = pane.applied_frame_id == commit.frame_id and
        capture.model.version().frame == commit.frame_revision;

    if (capture.fail_delivery) {
        return error.ResourceSyncFailed;
    }
}
