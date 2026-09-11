const Capture = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("agent_snapshot_delivery.zig");
const Effects = @import("AgentSnapshotDeliveryEffects.zig");
const notification_capability = @import("../../root.zig").notifications;
model: *const client_model.Model,
commit: *const client_model.AgentSnapshotCommit,
events: [8]source_namespace.Event = undefined,
event_count: usize = 0,
alert_count: usize = 0,
alerts_valid: bool = true,
commit_observed: bool = true,
failure: source_namespace.Failure = .none,

pub fn effects(capture: *Capture) Effects {
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

fn publishAlert(context: *anyopaque, input: notification_capability.Input) !void {
    const capture: *Capture = @ptrCast(@alignCast(context));
    capture.append(.publish_alert);
    capture.alerts_valid = capture.alerts_valid and source_namespace.expectedAlert(input, capture.alert_count);
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

fn append(capture: *Capture, event: source_namespace.Event) void {
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

pub fn eventSlice(capture: *const Capture) []const source_namespace.Event {
    return capture.events[0..capture.event_count];
}
