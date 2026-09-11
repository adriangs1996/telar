const source_namespace = @import("request_snapshot.zig");
/// Builds a statically dispatched snapshot controller for the cell delivery
/// path.
///
/// ```zig
/// const SnapshotController = Controller(*request_snapshot_commands.RequestCellSnapshotHandler);
/// var controller = SnapshotController.init(&metrics, &handler);
/// ```
pub fn Type(comptime Executor: type) type {
    return struct {
        const Self = @This();

        metrics: *source_namespace.RuntimeMetrics,
        executor: Executor,

        /// Creates one controller bound to the requesting client and handler.
        ///
        /// ```zig
        /// var controller = SnapshotController.init(&metrics, &handler);
        /// ```
        pub fn init(metrics: *source_namespace.RuntimeMetrics, executor: Executor) Self {
            return .{ .metrics = metrics, .executor = executor };
        }

        /// Requests a fresh server baseline for one pane. `known_frame_id` is
        /// advisory: recovery never trusts or replays the client's local
        /// baseline, so the pending recovery frame is always a full snapshot.
        ///
        /// ```zig
        /// try controller.requestSnapshot(request);
        /// ```
        pub inline fn requestSnapshot(controller: *Self, request: source_namespace.schema.RequestSnapshot) !void {
            _ = request.known_frame_id;
            const result = try controller.executor.execute(.{ .pane_id = request.pane_id });

            if (result == .pane_not_attached) {
                controller.metrics.stale_client_messages += 1;
            }
        }
    };
}
