const RuntimeMetricsType = @import("../../observability/RuntimeMetrics.zig");
const PaneResizeType = @import("telar-core").PaneResize;

/// Builds a statically dispatched resize controller for the interactive path.
///
/// ```zig
/// const ResizeController = Controller(*pane_resize_commands.PaneResizeHandler);
/// var controller = ResizeController.init(&metrics, &handler);
/// ```
pub fn Type(comptime Executor: type) type {
    return struct {
        const Self = @This();

        metrics: *RuntimeMetricsType,
        executor: Executor,

        /// Creates one controller bound to the requesting client and handler.
        ///
        /// ```zig
        /// var controller = ResizeController.init(&metrics, &handler);
        /// ```
        pub fn init(metrics: *RuntimeMetricsType, executor: Executor) Self {
            return .{ .metrics = metrics, .executor = executor };
        }

        /// Maps attachment and geometry rejection to diagnostics while
        /// preserving scheduler and PTY failures as infrastructure errors.
        ///
        /// ```zig
        /// try controller.paneResize(request);
        /// ```
        pub inline fn paneResize(controller: *Self, request: PaneResizeType) !void {
            const result = try controller.executor.execute(.{
                .pane_id = request.pane_id,
                .size = request.size,
            });

            switch (result) {
                .handled => {},
                .pane_not_attached => controller.metrics.stale_client_messages += 1,
                .geometry_rejected => controller.metrics.geometry_rejections += 1,
            }
        }
    };
}
