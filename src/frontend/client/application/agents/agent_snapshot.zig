//! Application use case for committing one runtime agent snapshot.

const std = @import("std");
const core = @import("telar-core");
const agents = @import("../../../agents/root.zig");
const client_model = @import("../../model/root.zig");

const schema = core.schema;

pub const AgentSnapshotDelivery = struct {
    context: *anyopaque,
    deliver: *const fn (*anyopaque, *const client_model.AgentSnapshotCommit) anyerror!void,
};

pub const ApplyAgentSnapshotHandler = struct {
    model: *client_model.Model,
    delivery: AgentSnapshotDelivery,

    /// Commits one newer replica before delivering its exact result. Stale
    /// snapshots and rejected candidates never cross the delivery boundary.
    ///
    /// ```zig
    /// const commit = try handler.execute(snapshot) orelse return;
    /// ```
    pub fn execute(handler: *ApplyAgentSnapshotHandler, snapshot: agents.SnapshotInput) !?client_model.AgentSnapshotCommit {
        const commit = try handler.model.reconcileAgentSnapshot(snapshot) orelse return null;
        try handler.delivery.deliver(handler.delivery.context, &commit);

        return commit;
    }
};

const DeliveryCapture = struct {
    model: *const client_model.Model,
    calls: usize = 0,
    observed_commit: bool = false,
    fail: bool = false,

    fn port(capture: *DeliveryCapture) AgentSnapshotDelivery {
        return .{ .context = capture, .deliver = deliver };
    }

    fn reset(capture: *DeliveryCapture) void {
        capture.calls = 0;
        capture.observed_commit = false;
    }

    fn deliver(context: *anyopaque, commit: *const client_model.AgentSnapshotCommit) !void {
        const capture: *DeliveryCapture = @ptrCast(@alignCast(context));
        capture.calls += 1;
        capture.observed_commit = capture.model.version().agents == commit.agent_revision and
            capture.model.agentSnapshot().revision == commit.runtime_revision and
            capture.model.agentSnapshot().count == commit.count and
            commit.agent_revision_before +% 1 == commit.agent_revision;

        if (capture.fail) {
            return error.AgentSnapshotDeliveryFailed;
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

test "ApplyAgentSnapshotHandler commits before exact delivery" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: DeliveryCapture = .{ .model = &model };
    var handler: ApplyAgentSnapshotHandler = .{
        .model = &model,
        .delivery = capture.port(),
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
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(@as(usize, 4), commit.status_changes.slice().len);
    try std.testing.expectEqual(client_model.Version{ .agents = 2 }, model.version());
}

test "ApplyAgentSnapshotHandler suppresses delivery for stale and rejected snapshots" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: DeliveryCapture = .{ .model = &model };
    var handler: ApplyAgentSnapshotHandler = .{
        .model = &model,
        .delivery = capture.port(),
    };
    const agent = agentInput(1, .blocked);

    _ = try handler.execute(.{ .revision = 1, .agents = &.{agent} });

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    capture.reset();
    try std.testing.expect((try handler.execute(.{ .revision = 1, .agents = &.{agent} })) == null);
    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try std.testing.expectError(error.DuplicateAgent, handler.execute(.{
        .revision = 2,
        .agents = &.{ agent, agent },
    }));
    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try std.testing.expectEqual(client_model.Version{ .agents = 1 }, model.version());
}

test "ApplyAgentSnapshotHandler preserves a model commit after delivery failure" {
    var model = client_model.Model.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: DeliveryCapture = .{
        .model = &model,
        .fail = true,
    };
    var handler: ApplyAgentSnapshotHandler = .{
        .model = &model,
        .delivery = capture.port(),
    };
    const agent = agentInput(1, .working);

    try std.testing.expectError(error.AgentSnapshotDeliveryFailed, handler.execute(.{
        .revision = 1,
        .agents = &.{agent},
    }));

    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqual(client_model.Version{ .agents = 1 }, model.version());
    try std.testing.expect(model.knowsAgent(agent.key));
}
