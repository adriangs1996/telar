//! Application policy for delivering dependent client state after one agent
//! snapshot commit.

const std = @import("std");
const core = @import("telar-core");
const agents = @import("../../../agents/root.zig");
const notification_capability = @import("../../../notifications/root.zig");
const client_model = @import("../../model/root.zig");

const schema = core.schema;

pub const Effects = struct {
    context: *anyopaque,
    synchronize_attachments: *const fn (*anyopaque) anyerror!void,
    publish_alert: *const fn (*anyopaque, notification_capability.Input) anyerror!void,
    synchronize_animation: *const fn (*anyopaque) anyerror!void,
};

pub const DeliverAgentSnapshotHandler = struct {
    model: *const client_model.Model,
    effects: Effects,

    /// Validates one exact commit before synchronizing attachments, publishing
    /// bounded actionable alerts and reconciling sidebar animation in order.
    ///
    /// ```zig
    /// try handler.execute(&commit);
    /// ```
    pub fn execute(handler: *DeliverAgentSnapshotHandler, commit: *const client_model.AgentSnapshotCommit) !void {
        try handler.validate(commit);
        try handler.effects.synchronize_attachments(handler.effects.context);

        var alert_count: usize = 0;
        const snapshot = handler.model.agentSnapshot();
        for (commit.status_changes.slice()) |change| {
            if (alert_count == notification_capability.max_items) {
                break;
            }

            var message_buffer: [96]u8 = undefined;
            const label = if (snapshot.find(change.key)) |agent| agent.displayName() else core.agent_manifest.generic_display_name;
            const alert = alertInput(change, label, &message_buffer) orelse continue;

            try handler.effects.publish_alert(handler.effects.context, alert);
            alert_count += 1;
        }

        try handler.effects.synchronize_animation(handler.effects.context);
    }

    fn validate(handler: *const DeliverAgentSnapshotHandler, commit: *const client_model.AgentSnapshotCommit) !void {
        const snapshot = handler.model.agentSnapshot();
        const change_count: usize = commit.status_changes.count;
        if (snapshot.revision != commit.runtime_revision or
            @as(usize, snapshot.count) != commit.count or
            handler.model.version().agents != commit.agent_revision or
            commit.agent_revision_before +% 1 != commit.agent_revision or
            change_count > commit.status_changes.items.len or
            change_count > commit.count)
        {
            return error.StaleAgentSnapshotCommit;
        }

        const changes = commit.status_changes.items[0..change_count];
        for (changes, 0..) |change, index| {
            const agent = snapshot.find(change.key) orelse return error.StaleAgentSnapshotCommit;
            if (agent.pane_index != change.pane_index or
                agent.provider != change.provider or
                agent.status != change.current or
                change.previous == change.current)
            {
                return error.StaleAgentSnapshotCommit;
            }

            for (changes[0..index]) |previous| {
                if (std.meta.eql(previous.key, change.key)) {
                    return error.StaleAgentSnapshotCommit;
                }
            }
        }
    }
};

fn alertInput(change: client_model.AgentStatusChange, label: []const u8, message_buffer: *[96]u8) ?notification_capability.Input {
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

fn statusName(status: schema.AgentStatus) []const u8 {
    return switch (status) {
        .blocked => "waiting for input",
        .done => "done",
        .ready => "ready",
        .failed => "failed",
        .unknown, .working => "active",
    };
}

const Event = enum {
    synchronize_attachments,
    publish_alert,
    synchronize_animation,
};

const Failure = enum {
    none,
    attachments,
    alert,
    animation,
};

const Capture = struct {
    model: *const client_model.Model,
    commit: *const client_model.AgentSnapshotCommit,
    events: [8]Event = undefined,
    event_count: usize = 0,
    alert_count: usize = 0,
    alerts_valid: bool = true,
    commit_observed: bool = true,
    failure: Failure = .none,

    fn effects(capture: *Capture) Effects {
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
        capture.alerts_valid = capture.alerts_valid and expectedAlert(input, capture.alert_count);
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

    fn append(capture: *Capture, event: Event) void {
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

    fn eventSlice(capture: *const Capture) []const Event {
        return capture.events[0..capture.event_count];
    }
};

const testing_location: schema.TabLocation = .{
    .workspace = .{ .workspace = @enumFromInt(1) },
    .tab_id = @enumFromInt(1),
};

fn commitStatuses(model: *client_model.Model, revision: u64, statuses: []const schema.AgentStatus) !client_model.AgentSnapshotCommit {
    var inputs: [6]agents.AgentInput = undefined;
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

fn expectedAlert(input: notification_capability.Input, index: usize) bool {
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

fn deliveryHandler(model: *const client_model.Model, capture: *Capture) DeliverAgentSnapshotHandler {
    return .{ .model = model, .effects = capture.effects() };
}

test "DeliverAgentSnapshotHandler orders attachments bounded alerts and animation" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    _ = try commitStatuses(&model, 1, &.{ .working, .working, .working, .working, .working, .working });
    const commit = try commitStatuses(&model, 2, &.{ .blocked, .done, .failed, .unknown, .blocked, .done });
    var capture: Capture = .{ .model = &model, .commit = &commit };
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
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    const commit = try commitStatuses(&model, 1, &.{.working});
    var capture: Capture = .{ .model = &model, .commit = &commit };
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
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    _ = try commitStatuses(&model, 1, &.{ .working, .working });
    const commit = try commitStatuses(&model, 2, &.{ .blocked, .done });
    var capture: Capture = .{ .model = &model, .commit = &commit };
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
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    _ = try commitStatuses(&model, 1, &.{ .working, .working, .working, .working, .working, .working });
    const commit = try commitStatuses(&model, 2, &.{ .blocked, .done, .failed, .unknown, .blocked, .done });

    var attachments: Capture = .{ .model = &model, .commit = &commit, .failure = .attachments };
    var attachments_handler = deliveryHandler(&model, &attachments);
    try std.testing.expectError(error.AttachmentSynchronizationFailed, attachments_handler.execute(&commit));
    try std.testing.expectEqualSlices(Event, &.{.synchronize_attachments}, attachments.eventSlice());

    var alert: Capture = .{ .model = &model, .commit = &commit, .failure = .alert };
    var alert_handler = deliveryHandler(&model, &alert);
    try std.testing.expectError(error.AlertPublicationFailed, alert_handler.execute(&commit));
    try std.testing.expectEqualSlices(Event, &.{ .synchronize_attachments, .publish_alert }, alert.eventSlice());

    var animation: Capture = .{ .model = &model, .commit = &commit, .failure = .animation };
    var animation_handler = deliveryHandler(&model, &animation);
    try std.testing.expectError(error.AnimationSynchronizationFailed, animation_handler.execute(&commit));
    try std.testing.expectEqual(Event.synchronize_animation, animation.eventSlice()[animation.event_count - 1]);
    try std.testing.expectEqual(notification_capability.max_items, animation.alert_count);
    try std.testing.expect(animation.commit_observed);
}
