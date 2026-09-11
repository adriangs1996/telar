const RuntimeMetricsType = @import("../../observability/RuntimeMetrics.zig");
const PaneInputType = @import("telar-core").PaneInput;
const pane_input_commands = @import("../../application/commands/pane_input.zig");

/// Builds a controller around a statically dispatched command executor. The
/// concrete executor remains visible to the compiler so this protocol boundary
/// adds neither allocation nor indirect dispatch to the interactive path.
///
/// ```zig
/// const InputController = Controller(*pane_input_commands.PaneInputHandler);
/// var controller = InputController.init(&metrics, &handler);
/// ```
pub fn Type(comptime Executor: type) type {
    return struct {
        const Self = @This();

        metrics: *RuntimeMetricsType,
        executor: Executor,

        /// Creates one controller bound to the requesting client and handler.
        ///
        /// ```zig
        /// var controller = InputController.init(&metrics, &handler);
        /// ```
        pub fn init(metrics: *RuntimeMetricsType, executor: Executor) Self {
            return .{ .metrics = metrics, .executor = executor };
        }

        /// Forwards valid input and treats an absent or exited attachment as a
        /// stale client message. Scheduling failures remain infrastructure
        /// errors and propagate to the runtime's connection policy.
        ///
        /// ```zig
        /// try controller.paneInput(request);
        /// ```
        pub inline fn paneInput(controller: *Self, request: PaneInputType) !pane_input_commands.PaneInputResult {
            const result = try controller.executor.execute(.{
                .pane_id = request.pane_id,
                .bytes = request.bytes,
            });

            switch (result) {
                .handled => {},
                .pane_not_attached, .pane_exited => {
                    controller.metrics.stale_client_messages += 1;
                },
            }

            return result;
        }
    };
}
