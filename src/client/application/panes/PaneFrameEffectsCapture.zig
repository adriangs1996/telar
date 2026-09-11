const ModelType = @import("../../model/Model.zig");
const pane_frame = @import("pane_frame.zig");
const PaneFrameRecoveryType = @import("../../model/PaneFrameRecovery.zig");
const PaneFrameCommitType = @import("../../model/PaneFrameCommit.zig");
const PaneFrameEffects = @import("PaneFrameEffects.zig");
const EffectsCapture = @This();

model: *ModelType,
events: [1]pane_frame.EffectEvent = undefined,
event_count: usize = 0,
recovery: ?PaneFrameRecoveryType = null,
commit: ?PaneFrameCommitType = null,
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

fn record(capture: *EffectsCapture, event: pane_frame.EffectEvent) void {
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

fn recover(context: *anyopaque, recovery: PaneFrameRecoveryType) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    capture.record(.recover);
    capture.recovery = recovery;

    if (capture.fail_recovery) {
        return error.RecoveryFailed;
    }
}

fn deliver(context: *anyopaque, commit: PaneFrameCommitType) !void {
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
