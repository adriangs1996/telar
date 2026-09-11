//! Protocol controller for one client's agent acknowledgement. Accepted
//! requests have no direct response; a changed projection reaches every
//! client through the next agent snapshot.

const std = @import("std");
const core = @import("telar-core");
const acknowledge_agent_commands = @import("../../application/commands/acknowledge_agent.zig");
const telemetry_mod = @import("../../observability/root.zig").telemetry;

pub const schema = core.schema;
pub const RuntimeMetrics = telemetry_mod.RuntimeMetrics;

pub const Controller = @import("GenericAcknowledgeAgentController.zig").Type;

const StubExecutor = @import("AcknowledgeAgentStubExecutor.zig");

const TestController = Controller(*StubExecutor);

test "Controller maps the exact agent generation and clock" {
    const pane_id = try schema.id.pane(7);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var stub: StubExecutor = .{};
    var controller = TestController.init(&metrics, &stub);

    controller.acknowledgeAgent(.{ .pane_id = pane_id, .pane_generation = 3 }, 41);

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqual(pane_id, stub.command.?.pane_id);
    try std.testing.expectEqual(@as(u64, 3), stub.command.?.pane_generation);
    try std.testing.expectEqual(@as(i64, 41), stub.command.?.now_ms);
    try std.testing.expectEqual(@as(u64, 0), metrics.stale_client_messages);
}

test "Controller counts only an unknown generation as stale" {
    var metrics: RuntimeMetrics = .{ .started_ns = 0, .stale_client_messages = 4 };
    var stub: StubExecutor = .{ .result = .unchanged };
    var controller = TestController.init(&metrics, &stub);

    controller.acknowledgeAgent(.{ .pane_id = try schema.id.pane(7), .pane_generation = 3 }, 0);
    try std.testing.expectEqual(@as(u64, 4), metrics.stale_client_messages);

    stub.result = .unknown_agent;
    controller.acknowledgeAgent(.{ .pane_id = try schema.id.pane(7), .pane_generation = 2 }, 0);
    try std.testing.expectEqual(@as(u64, 5), metrics.stale_client_messages);
}
