//! Application policy for delivering dependent client state after one agent
//! snapshot commit.

const AgentStatusChangeType = @import("../../model/AgentStatusChange.zig");
const InputType = @import("../../notifications/NotificationInput.zig");
const notification_capability = @import("../../notifications/notifications.zig");
const std = @import("std");
const AgentStatusType = @import("telar-core").AgentStatus;
const TabLocationType = @import("telar-core").TabLocation;
const ModelType = @import("../../model/Model.zig");
const AgentSnapshotCommitType = @import("../../model/AgentSnapshotCommit.zig");
const AgentInputType = @import("../../agents/AgentInput.zig");
const AgentSnapshotDeliveryCaptureType = @import("AgentSnapshotDeliveryCaptureType.zig");
const DeliverAgentSnapshotHandler = @import("DeliverAgentSnapshotHandler.zig");

pub fn alertInput(change: AgentStatusChangeType, label: []const u8, message_buffer: *[96]u8) ?InputType {
    const level: notification_capability.Level = switch (change.current) {
        .blocked => .warning,
        .done => .success,
        .failed => .failure,
        .unknown, .working, .ready => return null,
    };
    const message = std.fmt.bufPrint(
        message_buffer,
        "{s} in pane {d} is {s}",
        .{ label, change.pane_index, statusName(change.current) },
    ) catch "Agent status changed";

    return .{
        .level = level,
        .title = switch (change.current) {
            .blocked => "Agent needs input",
            .done => "Agent done",
            .failed => "Agent failed",
            .unknown, .working, .ready => unreachable,
        },
        .message = message,
        .target = .{ .focus_pane = change.key.pane_id },
        .duration_ns = if (change.current == .failed)
            7 * std.time.ns_per_s
        else
            notification_capability.default_duration_ns,
    };
}

fn statusName(status: AgentStatusType) []const u8 {
    return switch (status) {
        .blocked => "waiting for input",
        .done => "done",
        .ready => "ready",
        .failed => "failed",
        .unknown, .working => "active",
    };
}

pub const Event = enum {
    synchronize_attachments,
    publish_alert,
    synchronize_animation,
};

pub const Failure = enum {
    none,
    attachments,
    alert,
    animation,
};

const testing_location: TabLocationType = .{
    .workspace = .{ .workspace = @enumFromInt(1) },
    .tab_id = @enumFromInt(1),
};

fn commitStatuses(model: *ModelType, revision: u64, statuses: []const AgentStatusType) !AgentSnapshotCommitType {
    var inputs: [6]AgentInputType = undefined;
    for (statuses, 0..) |status, index| {
        inputs[index] = .{
            .key = .{ .pane_id = @enumFromInt(index + 1), .pane_generation = 1 },
            .location = testing_location,
            .pane_index = @intCast(index + 1),
            .provider = switch (index) {
                0 => .codex,
                1 => .claude,
                2 => .unknown,
                else => .codex,
            },
            .display_name = switch (index) {
                0 => "Codex",
                1 => "Claude",
                2 => "",
                else => "Codex",
            },
            .status = status,
        };
    }

    return (try model.reconcileAgentSnapshot(.{
        .revision = revision,
        .agents = inputs[0..statuses.len],
    })).?;
}

pub fn expectedAlert(input: InputType, index: usize) bool {
    return switch (index) {
        0 => input.level == .warning and
            std.mem.eql(u8, input.title, "Agent needs input") and
            std.mem.eql(u8, input.message, "Codex in pane 1 is waiting for input") and
            std.meta.eql(input.target, notification_capability.Target{ .focus_pane = @enumFromInt(1) }) and
            input.duration_ns == notification_capability.default_duration_ns,
        1 => input.level == .success and
            std.mem.eql(u8, input.title, "Agent done") and
            std.mem.eql(u8, input.message, "Claude in pane 2 is done") and
            std.meta.eql(input.target, notification_capability.Target{ .focus_pane = @enumFromInt(2) }) and
            input.duration_ns == notification_capability.default_duration_ns,
        2 => input.level == .failure and
            std.mem.eql(u8, input.title, "Agent failed") and
            std.mem.eql(u8, input.message, "Agent in pane 3 is failed") and
            std.meta.eql(input.target, notification_capability.Target{ .focus_pane = @enumFromInt(3) }) and
            input.duration_ns == 7 * std.time.ns_per_s,
        3 => input.level == .warning and
            std.mem.eql(u8, input.title, "Agent needs input") and
            std.mem.eql(u8, input.message, "Codex in pane 5 is waiting for input") and
            std.meta.eql(input.target, notification_capability.Target{ .focus_pane = @enumFromInt(5) }) and
            input.duration_ns == notification_capability.default_duration_ns,
        else => false,
    };
}

fn deliveryHandler(model: *const ModelType, capture: *AgentSnapshotDeliveryCaptureType) DeliverAgentSnapshotHandler {
    return .{ .model = model, .effects = capture.effects() };
}

test "DeliverAgentSnapshotHandler orders attachments bounded alerts and animation" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    _ = try commitStatuses(&model, 1, &.{ .working, .working, .working, .working, .working, .working });
    const commit = try commitStatuses(&model, 2, &.{ .blocked, .done, .failed, .unknown, .blocked, .done });
    var capture: AgentSnapshotDeliveryCaptureType = .{ .model = &model, .commit = &commit };
    var handler = deliveryHandler(&model, &capture);

    try handler.execute(&commit);

    try std.testing.expectEqualSlices(Event, &.{
        .synchronize_attachments,
        .publish_alert,
        .publish_alert,
        .publish_alert,
        .publish_alert,
        .synchronize_animation,
    }, capture.eventSlice());
    try std.testing.expectEqual(notification_capability.max_items, capture.alert_count);
    try std.testing.expect(capture.alerts_valid);
    try std.testing.expect(capture.commit_observed);
}

test "DeliverAgentSnapshotHandler synchronizes resources without status changes" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    const commit = try commitStatuses(&model, 1, &.{.working});
    var capture: AgentSnapshotDeliveryCaptureType = .{ .model = &model, .commit = &commit };
    var handler = deliveryHandler(&model, &capture);

    try handler.execute(&commit);

    try std.testing.expectEqualSlices(Event, &.{
        .synchronize_attachments,
        .synchronize_animation,
    }, capture.eventSlice());
    try std.testing.expectEqual(@as(usize, 0), capture.alert_count);
    try std.testing.expect(capture.commit_observed);
}

test "DeliverAgentSnapshotHandler rejects stale commits before effects" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    _ = try commitStatuses(&model, 1, &.{ .working, .working });
    const commit = try commitStatuses(&model, 2, &.{ .blocked, .done });
    var capture: AgentSnapshotDeliveryCaptureType = .{ .model = &model, .commit = &commit };
    var handler = deliveryHandler(&model, &capture);

    var altered = commit;
    altered.runtime_revision -%= 1;
    try std.testing.expectError(error.StaleAgentSnapshotCommit, handler.execute(&altered));
    altered = commit;
    altered.count += 1;
    try std.testing.expectError(error.StaleAgentSnapshotCommit, handler.execute(&altered));
    altered = commit;
    altered.status_changes.count = @intCast(altered.status_changes.items.len + 1);
    try std.testing.expectError(error.StaleAgentSnapshotCommit, handler.execute(&altered));
    altered = commit;
    altered.agent_revision_before -%= 1;
    try std.testing.expectError(error.StaleAgentSnapshotCommit, handler.execute(&altered));
    altered = commit;
    altered.agent_revision -%= 1;
    try std.testing.expectError(error.StaleAgentSnapshotCommit, handler.execute(&altered));
    altered = commit;
    altered.status_changes.items[0].pane_index += 1;
    try std.testing.expectError(error.StaleAgentSnapshotCommit, handler.execute(&altered));
    altered = commit;
    altered.status_changes.items[0].provider = .claude;
    try std.testing.expectError(error.StaleAgentSnapshotCommit, handler.execute(&altered));
    altered = commit;
    altered.status_changes.items[0].current = .working;
    try std.testing.expectError(error.StaleAgentSnapshotCommit, handler.execute(&altered));
    altered = commit;
    altered.status_changes.items[0].previous = altered.status_changes.items[0].current;
    try std.testing.expectError(error.StaleAgentSnapshotCommit, handler.execute(&altered));
    altered = commit;
    altered.status_changes.items[1].key = altered.status_changes.items[0].key;
    try std.testing.expectError(error.StaleAgentSnapshotCommit, handler.execute(&altered));

    _ = try commitStatuses(&model, 3, &.{ .ready, .failed });
    try std.testing.expectError(error.StaleAgentSnapshotCommit, handler.execute(&commit));
    try std.testing.expectEqual(@as(usize, 0), capture.event_count);
}

test "DeliverAgentSnapshotHandler stops after each failed delivery stage" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    _ = try commitStatuses(&model, 1, &.{ .working, .working, .working, .working, .working, .working });
    const commit = try commitStatuses(&model, 2, &.{ .blocked, .done, .failed, .unknown, .blocked, .done });

    var attachments: AgentSnapshotDeliveryCaptureType = .{ .model = &model, .commit = &commit, .failure = .attachments };
    var attachments_handler = deliveryHandler(&model, &attachments);
    try std.testing.expectError(error.AttachmentSynchronizationFailed, attachments_handler.execute(&commit));
    try std.testing.expectEqualSlices(Event, &.{.synchronize_attachments}, attachments.eventSlice());

    var alert: AgentSnapshotDeliveryCaptureType = .{ .model = &model, .commit = &commit, .failure = .alert };
    var alert_handler = deliveryHandler(&model, &alert);
    try std.testing.expectError(error.AlertPublicationFailed, alert_handler.execute(&commit));
    try std.testing.expectEqualSlices(Event, &.{ .synchronize_attachments, .publish_alert }, alert.eventSlice());

    var animation: AgentSnapshotDeliveryCaptureType = .{ .model = &model, .commit = &commit, .failure = .animation };
    var animation_handler = deliveryHandler(&model, &animation);
    try std.testing.expectError(error.AnimationSynchronizationFailed, animation_handler.execute(&commit));
    try std.testing.expectEqual(Event.synchronize_animation, animation.eventSlice()[animation.event_count - 1]);
    try std.testing.expectEqual(notification_capability.max_items, animation.alert_count);
    try std.testing.expect(animation.commit_observed);
}
