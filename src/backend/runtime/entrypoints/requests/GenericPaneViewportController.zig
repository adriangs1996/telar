const RuntimeMetricsType = @import("../../observability/RuntimeMetrics.zig");
const SetPaneViewportType = @import("telar-core").SetPaneViewport;

/// Builds a statically dispatched viewport controller for the cell delivery
/// path.
///
/// ```zig
/// const ViewportController = Controller(*pane_viewport_commands.SetPaneViewportHandler);
/// var controller = ViewportController.init(&metrics, &handler);
/// ```
pub fn Type(comptime Executor: type) type {
    return struct {
        const Self = @This();

        metrics: *RuntimeMetricsType,
        executor: Executor,

        /// Creates one controller bound to the requesting client and handler.
        ///
        /// ```zig
        /// var controller = ViewportController.init(&metrics, &handler);
        /// ```
        pub fn init(metrics: *RuntimeMetricsType, executor: Executor) Self {
            return .{ .metrics = metrics, .executor = executor };
        }

        /// Maps the wire viewport to its command and counts only a missing
        /// attachment as stale. Allocation failures remain infrastructure
        /// errors after the attachment restores its previous state.
        ///
        /// ```zig
        /// try controller.setPaneViewport(viewport);
        /// ```
        pub inline fn setPaneViewport(controller: *Self, viewport: SetPaneViewportType) !void {
            const result = try controller.executor.execute(.{
                .pane_id = viewport.pane_id,
                .offset = viewport.offset,
            });

            if (result == .pane_not_attached) {
                controller.metrics.stale_client_messages += 1;
            }
        }
    };
}
