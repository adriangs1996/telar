const source_namespace = @import("request_graphics_snapshot.zig");
/// Builds a statically dispatched controller for graphics recovery requests.
///
/// ```zig
/// const GraphicsSnapshotController = Controller(*request_graphics_snapshot_commands.RequestGraphicsSnapshotHandler);
/// var controller = GraphicsSnapshotController.init(&metrics, &handler);
/// ```
pub fn Type(comptime Executor: type) type {
    return struct {
        const Self = @This();

        metrics: *source_namespace.RuntimeMetrics,
        executor: Executor,

        /// Creates one controller bound to the requesting client and handler.
        ///
        /// ```zig
        /// var controller = GraphicsSnapshotController.init(&metrics, &handler);
        /// ```
        pub fn init(metrics: *source_namespace.RuntimeMetrics, executor: Executor) Self {
            return .{ .metrics = metrics, .executor = executor };
        }

        /// Maps the wire request to an unconditional graphics recovery command
        /// and counts only a pane outside this client's attachments as stale.
        ///
        /// ```zig
        /// try controller.requestGraphicsSnapshot(request);
        /// ```
        pub inline fn requestGraphicsSnapshot(controller: *Self, request: source_namespace.schema.RequestGraphicsSnapshot) !void {
            const result = try controller.executor.execute(.{ .pane_id = request.pane_id });

            if (result == .pane_not_attached) {
                controller.metrics.stale_client_messages += 1;
            }
        }
    };
}
