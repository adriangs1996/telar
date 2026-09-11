const RuntimeMetricsType = @import("../../observability/RuntimeMetrics.zig");
const AcknowledgeAgentType = @import("telar-core").AcknowledgeAgent;

/// Builds a statically dispatched acknowledgement controller.
///
/// ```zig
/// const AcknowledgeController = Controller(*acknowledge_agent_commands.AcknowledgeAgentHandler);
/// var controller = AcknowledgeController.init(&metrics, &handler);
/// ```
pub fn Type(comptime Executor: type) type {
    return struct {
        const Self = @This();

        metrics: *RuntimeMetricsType,
        executor: Executor,

        /// Creates one controller bound to the runtime metrics and handler.
        ///
        /// ```zig
        /// var controller = AcknowledgeController.init(&metrics, &handler);
        /// ```
        pub fn init(metrics: *RuntimeMetricsType, executor: Executor) Self {
            return .{ .metrics = metrics, .executor = executor };
        }

        /// Maps the wire acknowledgement to its command and counts only an
        /// unknown generation as stale.
        ///
        /// ```zig
        /// controller.acknowledgeAgent(acknowledgement, now_ms);
        /// ```
        pub inline fn acknowledgeAgent(controller: *Self, acknowledgement: AcknowledgeAgentType, now_ms: i64) void {
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
