const RuntimeMetricsType = @import("../../observability/RuntimeMetrics.zig");
const GraphicsCreditType = @import("telar-core").GraphicsCredit;

/// Builds a statically dispatched controller for graphics flow control.
///
/// ```zig
/// const GraphicsCreditController = Controller(*graphics_credit_commands.ReturnGraphicsCreditHandler);
/// var controller = GraphicsCreditController.init(&metrics, &handler);
/// ```
pub fn Type(comptime Executor: type) type {
    return struct {
        const Self = @This();

        metrics: *RuntimeMetricsType,
        executor: Executor,

        /// Creates one controller bound to the requesting client and handler.
        ///
        /// ```zig
        /// var controller = GraphicsCreditController.init(&metrics, &handler);
        /// ```
        pub fn init(metrics: *RuntimeMetricsType, executor: Executor) Self {
            return .{ .metrics = metrics, .executor = executor };
        }

        /// Returns the exact wire amount and counts missing attachments or
        /// amounts outside the attachment's outstanding credit as stale.
        ///
        /// ```zig
        /// try controller.graphicsCredit(credit);
        /// ```
        pub inline fn graphicsCredit(controller: *Self, credit: GraphicsCreditType) !void {
            const result = try controller.executor.execute(.{
                .pane_id = credit.pane_id,
                .bytes = credit.bytes,
            });

            if (result != .returned) {
                controller.metrics.stale_client_messages += 1;
            }
        }
    };
}
