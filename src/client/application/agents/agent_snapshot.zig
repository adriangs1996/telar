//! Application use case for committing one runtime agent snapshot.

const AgentStatusType = @import("telar-core").AgentStatus;
const AgentInputType = @import("../../agents/AgentInput.zig");
const ModelType = @import("../../model/Model.zig");
const std = @import("std");
const AgentSnapshotDeliveryCapture = @import("AgentSnapshotDeliveryCapture.zig");
const ApplyAgentSnapshotHandler = @import("ApplyAgentSnapshotHandler.zig");
const VersionType = @import("../../model/Version.zig");

fn agentInput(pane: u64, status: AgentStatusType) AgentInputType {
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
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: AgentSnapshotDeliveryCapture = .{ .model = &model };
    var handler: ApplyAgentSnapshotHandler = .{
        .model = &model,
        .delivery = capture.port(),
    };
    const initial = [_]AgentInputType{
        agentInput(1, .working),
        agentInput(2, .working),
        agentInput(3, .working),
        agentInput(4, .working),
    };
    _ = try handler.execute(.{ .revision = 1, .agents = &initial });
    capture.reset();
    const changed = [_]AgentInputType{
        agentInput(1, .blocked),
        agentInput(2, .ready),
        agentInput(3, .failed),
        agentInput(4, .unknown),
    };

    const commit = (try handler.execute(.{ .revision = 2, .agents = &changed })).?;

    try std.testing.expect(capture.observed_commit);
    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expectEqual(@as(usize, 4), commit.status_changes.slice().len);
    try std.testing.expectEqual(VersionType{ .agents = 2 }, model.version());
}

test "ApplyAgentSnapshotHandler suppresses delivery for stale and rejected snapshots" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: AgentSnapshotDeliveryCapture = .{ .model = &model };
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
    try std.testing.expectEqual(VersionType{ .agents = 1 }, model.version());
}

test "ApplyAgentSnapshotHandler preserves a model commit after delivery failure" {
    var model = ModelType.init(std.testing.allocator, true);
    defer model.deinit();
    var capture: AgentSnapshotDeliveryCapture = .{
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
    try std.testing.expectEqual(VersionType{ .agents = 1 }, model.version());
    try std.testing.expect(model.knowsAgent(agent.key));
}
