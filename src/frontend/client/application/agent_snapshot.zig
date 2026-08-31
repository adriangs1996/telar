//! Application use case for reconciling runtime agent state and its effects.

const std = @import("std");
const core = @import("telar-core");
const agents = @import("../../agents/root.zig");
const client_model = @import("../model.zig");

const schema = core.schema;

pub const AgentSnapshotEffects = struct {
    context: *anyopaque,
    reconcile: *const fn (*anyopaque, *const client_model.AgentSnapshotCommit) anyerror!void,
    alert: *const fn (*anyopaque, client_model.AgentStatusChange) anyerror!void,
    alert_limit: usize,
};

pub const ApplyAgentSnapshotHandler = struct {
    model: *client_model.Model,
    effects: AgentSnapshotEffects,

    /// Commits one newer replica before synchronizing dependent resources.
    /// Only actionable transitions for existing identities emit bounded alerts.
    ///
    /// ```zig
    /// const commit = try handler.execute(snapshot) orelse return;
    /// ```
    pub fn execute(handler: *ApplyAgentSnapshotHandler, snapshot: agents.SnapshotInput) !?client_model.AgentSnapshotCommit {
        const commit = try handler.model.reconcileAgentSnapshot(snapshot) orelse return null;
        try handler.effects.reconcile(handler.effects.context, &commit);

        var alert_count: usize = 0;
        for (commit.status_changes.slice()) |change| {
            if (!actionable(change.current)) {
                continue;
            }
            if (alert_count == handler.effects.alert_limit) {
                break;
            }

            try handler.effects.alert(handler.effects.context, change);
            alert_count += 1;
        }

        return commit;
    }
};

fn actionable(status: schema.AgentStatus) bool {
    return status == .blocked or status == .ready or status == .failed;
}

const EffectsCapture = struct {
    model: *const client_model.Model,
    reconcile_count: usize = 0,
    alerts: [agents.max_agents]client_model.AgentStatusChange = undefined,
    alert_count: usize = 0,
    observed_commit: bool = false,
    fail_reconcile: bool = false,
    fail_alert: bool = false,

    fn port(capture: *EffectsCapture, alert_limit: usize) AgentSnapshotEffects {
        return .{
            .context = capture,
            .reconcile = reconcile,
            .alert = alert,
            .alert_limit = alert_limit,
        };
    }

    fn reset(capture: *EffectsCapture) void {
        capture.reconcile_count = 0;
        capture.alert_count = 0;
        capture.observed_commit = false;
    }

    fn reconcile(context: *anyopaque, commit: *const client_model.AgentSnapshotCommit) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.reconcile_count += 1;
        capture.observed_commit = capture.model.version().agents == commit.agent_revision and
            capture.model.agentSnapshot().revision == commit.runtime_revision;

        if (capture.fail_reconcile) {
            return error.ReconcileFailed;
        }
    }

    fn alert(context: *anyopaque, change: client_model.AgentStatusChange) !void {
        const capture: *EffectsCapture = @ptrCast(@alignCast(context));
        capture.alerts[capture.alert_count] = change;
        capture.alert_count += 1;

        if (capture.fail_alert) {
            return error.AlertFailed;
        }
    }
};

fn agentInput(pane: u64, status: schema.AgentStatus) agents.AgentInput {
    return .{
        .key = .{ .pane_id = @enumFromInt(pane), .pane_generation = 1 },
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        },
        .pane_index = @intCast(pane),
        .provider = .codex,
        .status = status,
    };
}

test "ApplyAgentSnapshotHandler commits before reconciliation and bounds actionable alerts" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: EffectsCapture = .{ .model = &model };
    var handler: ApplyAgentSnapshotHandler = .{
        .model = &model,
        .effects = capture.port(2),
    };
    const initial = [_]agents.AgentInput{
        agentInput(1, .working),
        agentInput(2, .working),
        agentInput(3, .working),
        agentInput(4, .working),
    };
    _ = try handler.execute(.{ .revision = 1, .agents = &initial });
    capture.reset();
    const changed = [_]agents.AgentInput{
        agentInput(1, .blocked),
        agentInput(2, .ready),
        agentInput(3, .failed),
        agentInput(4, .unknown),
    };

    const commit = (try handler.execute(.{ .revision = 2, .agents = &changed })).?;

    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqual(@as(usize, 1), capture.reconcile_count);
    try std.testing.expectEqual(@as(usize, 2), capture.alert_count);
    try std.testing.expectEqual(schema.AgentStatus.blocked, capture.alerts[0].current);
    try std.testing.expectEqual(schema.AgentStatus.ready, capture.alerts[1].current);
    try std.testing.expectEqual(@as(usize, 4), commit.status_changes.slice().len);
    try std.testing.expectEqual(client_model.Version{ .agents = 2 }, model.version());
}

test "ApplyAgentSnapshotHandler suppresses new stale and rejected alerts" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: EffectsCapture = .{ .model = &model };
    var handler: ApplyAgentSnapshotHandler = .{
        .model = &model,
        .effects = capture.port(4),
    };
    const agent = agentInput(1, .blocked);

    _ = try handler.execute(.{ .revision = 1, .agents = &.{agent} });

    try std.testing.expectEqual(@as(usize, 1), capture.reconcile_count);
    try std.testing.expectEqual(@as(usize, 0), capture.alert_count);
    capture.reset();
    try std.testing.expect((try handler.execute(.{ .revision = 1, .agents = &.{agent} })) == null);
    try std.testing.expectEqual(@as(usize, 0), capture.reconcile_count);
    try std.testing.expectEqual(@as(usize, 0), capture.alert_count);
    try std.testing.expectError(error.DuplicateAgent, handler.execute(.{
        .revision = 2,
        .agents = &.{ agent, agent },
    }));
    try std.testing.expectEqual(@as(usize, 0), capture.reconcile_count);
    try std.testing.expectEqual(@as(usize, 0), capture.alert_count);
    try std.testing.expectEqual(client_model.Version{ .agents = 1 }, model.version());
}

test "ApplyAgentSnapshotHandler preserves a model commit after effect failure" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: EffectsCapture = .{
        .model = &model,
        .fail_reconcile = true,
    };
    var handler: ApplyAgentSnapshotHandler = .{
        .model = &model,
        .effects = capture.port(4),
    };
    const agent = agentInput(1, .working);

    try std.testing.expectError(error.ReconcileFailed, handler.execute(.{
        .revision = 1,
        .agents = &.{agent},
    }));

    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqual(client_model.Version{ .agents = 1 }, model.version());
    try std.testing.expect(model.knowsAgent(agent.key));

    capture.fail_reconcile = false;
    capture.fail_alert = true;
    capture.reset();
    var blocked = agent;
    blocked.status = .blocked;
    try std.testing.expectError(error.AlertFailed, handler.execute(.{
        .revision = 2,
        .agents = &.{blocked},
    }));

    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqual(@as(usize, 1), capture.alert_count);
    try std.testing.expectEqual(client_model.Version{ .agents = 2 }, model.version());
    try std.testing.expectEqual(schema.AgentStatus.blocked, model.agentSnapshot().find(agent.key).?.status);
}
