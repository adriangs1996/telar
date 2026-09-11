const ModelType = @import("../../model/Model.zig");
const AgentSnapshotCommitType = @import("../../model/AgentSnapshotCommit.zig");
const agent_snapshot_delivery = @import("agent_snapshot_delivery.zig");
const AgentSnapshotDeliveryEffects = @import("AgentSnapshotDeliveryEffects.zig");
const InputType = @import("../../notifications/NotificationInput.zig");
const Capture = @This();

model: *const ModelType,
commit: *const AgentSnapshotCommitType,
events: [8]agent_snapshot_delivery.Event = undefined,
event_count: usize = 0,
alert_count: usize = 0,
alerts_valid: bool = true,
commit_observed: bool = true,
failure: agent_snapshot_delivery.Failure = .none,

pub fn effects(capture: *Capture) AgentSnapshotDeliveryEffects {
    return .{
        .context = capture,
        .synchronize_attachments = synchronizeAttachments,
        .publish_alert = publishAlert,
        .synchronize_animation = synchronizeAnimation,
    };
}

fn synchronizeAttachments(context: *anyopaque) !void {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.append(.synchronize_attachments);

    if (capture.failure == .attachments) {
        return error.AttachmentSynchronizationFailed;
    }
}

fn publishAlert(context: *anyopaque, input: InputType) !void {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.append(.publish_alert);
    capture.alerts_valid = capture.alerts_valid and agent_snapshot_delivery.expectedAlert(input, capture.alert_count);
    capture.alert_count += 1;

    if (capture.failure == .alert) {
        return error.AlertPublicationFailed;
    }
}

fn synchronizeAnimation(context: *anyopaque) !void {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.append(.synchronize_animation);

    if (capture.failure == .animation) {
        return error.AnimationSynchronizationFailed;
    }
}

fn append(capture: *Capture, event: agent_snapshot_delivery.Event) void {
    capture.observeCommit();
    capture.events[capture.event_count] = event;
    capture.event_count += 1;
}

fn observeCommit(capture: *Capture) void {
    const snapshot = capture.model.agentSnapshot();
    capture.commit_observed = capture.commit_observed and
        snapshot.revision == capture.commit.runtime_revision and
        @as(usize, snapshot.count) == capture.commit.count and
        capture.model.version().agents == capture.commit.agent_revision and
        capture.commit.agent_revision_before +% 1 == capture.commit.agent_revision;
}

pub fn eventSlice(capture: *const Capture) []const agent_snapshot_delivery.Event {
    return capture.events[0..capture.event_count];
}
