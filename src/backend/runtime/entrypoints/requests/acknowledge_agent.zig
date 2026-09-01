//! Protocol controller for one client's agent acknowledgement. Accepted
//! requests have no direct response; a changed projection reaches every
//! client through the next agent snapshot.

const std = @import("std");
const core = @import("telar-core");
const acknowledge_agent_commands = @import("../../application/commands/acknowledge_agent.zig");
const telemetry_mod = @import("../../observability/root.zig").telemetry;

const schema = core.schema;
const RuntimeMetrics = telemetry_mod.RuntimeMetrics;

/// Builds a statically dispatched acknowledgement controller.
///
/// ```zig
/// const AcknowledgeController = Controller(*acknowledge_agent_commands.AcknowledgeAgentHandler);
/// var controller = AcknowledgeController.init(&metrics, &handler);
/// ```
pub fn Controller(comptime Executor: type) type {
    return struct {
        const Self = @This();

        metrics: *RuntimeMetrics,
        executor: Executor,

        /// Creates one controller bound to the runtime metrics and handler.
        ///
        /// ```zig
        /// var controller = AcknowledgeController.init(&metrics, &handler);
        /// ```
        pub fn init(metrics: *RuntimeMetrics, executor: Executor) Self {
            return .{ .metrics = metrics, .executor = executor };
        }

        /// Maps the wire acknowledgement to its command and counts only an
        /// unknown generation as stale.
        ///
        /// ```zig
        /// controller.acknowledgeAgent(acknowledgement, now_ms);
        /// ```
        pub inline fn acknowledgeAgent(controller: *Self, acknowledgement: schema.AcknowledgeAgent, now_ms: i64) void {
            const result = controller.executor.execute(.{
                .pane_id = acknowledgement.pane_id,
                .pane_generation = acknowledgement.pane_generation,
                .now_ms = now_ms,
            });

            if (result == .unknown_agent) {
                controller.metrics.stale_client_messages += 1;
            }
        }
    };
}

const StubExecutor = struct {
    result: acknowledge_agent_commands.AcknowledgeAgentResult = .acknowledged,
    call_count: usize = 0,
    command: ?acknowledge_agent_commands.AcknowledgeAgent = null,

    fn execute(stub: *StubExecutor, command: acknowledge_agent_commands.AcknowledgeAgent) acknowledge_agent_commands.AcknowledgeAgentResult {
        stub.call_count += 1;
        stub.command = command;
        return stub.result;
    }
};

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
