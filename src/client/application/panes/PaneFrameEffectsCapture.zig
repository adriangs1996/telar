const ModelType = @import("../../model/Model.zig");
const pane_frame = @import("pane_frame.zig");
const PaneFrameRecoveryType = @import("../../model/PaneFrameRecovery.zig");
const PaneFrameCommitType = @import("../../model/PaneFrameCommit.zig");
const PaneFrameEffects = @import("PaneFrameEffects.zig");
const FrameAckType = @import("telar-core").FrameAck;
const EffectsCapture = @This();

model: *ModelType,
events: [2]pane_frame.EffectEvent = undefined,
event_count: usize = 0,
recovery: ?PaneFrameRecoveryType = null,
commit: ?PaneFrameCommitType = null,
ack: ?FrameAckType = null,
ack_observed_commit: bool = false,
observed_commit: bool = false,
fail_recovery: bool = false,
fail_delivery: bool = false,
fail_ack: bool = false,

pub fn port(capture: *EffectsCapture) PaneFrameEffects {
    return .{
        .context = capture,
        .recover = recover,
        .acknowledge = acknowledge,
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

fn acknowledge(context: *anyopaque, ack: FrameAckType) !void {
    const capture: *EffectsCapture = @ptrCast(@alignCast(context));
    const pane = capture.model.workspace.findPane(ack.pane_id).?;
    capture.record(.acknowledge);
    capture.ack = ack;
    capture.ack_observed_commit = pane.applied_frame_id == ack.frame_id and pane.pending_frame_id == ack.frame_id;

    if (capture.fail_ack) {
        return error.AcknowledgementFailure;
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
