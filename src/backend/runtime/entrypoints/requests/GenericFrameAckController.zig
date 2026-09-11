const source_namespace = @import("frame_ack.zig");
/// Builds a statically dispatched acknowledgement controller for the cell
/// delivery path.
///
/// ```zig
/// const AckController = Controller(*frame_ack_commands.FrameAckHandler);
/// var controller = AckController.init(io, &metrics, &handler);
/// ```
pub fn Type(comptime Executor: type) type {
    return struct {
        const Self = @This();

        io: source_namespace.Io,
        metrics: *source_namespace.RuntimeMetrics,
        executor: Executor,

        /// Creates one controller bound to the requesting client and handler.
        ///
        /// ```zig
        /// var controller = AckController.init(io, &metrics, &handler);
        /// ```
        pub fn init(io: source_namespace.Io, metrics: *source_namespace.RuntimeMetrics, executor: Executor) Self {
            return .{ .io = io, .metrics = metrics, .executor = executor };
        }

        /// Samples receipt time, maps the wire ACK to its application command,
        /// and records stale messages or accepted-frame latency.
        ///
        /// ```zig
        /// try controller.frameAck(ack);
        /// ```
        pub inline fn frameAck(controller: *Self, ack: source_namespace.schema.FrameAck) !void {
            const result = try controller.executor.execute(.{
                .pane_id = ack.pane_id,
                .frame_id = ack.frame_id,
                .received_at_ns = source_namespace.diagnostics.now(controller.io),
            });

            switch (result) {
                .acknowledged => |elapsed| {
                    if (comptime source_namespace.diagnostics.enabled) {
                        controller.metrics.ack.observe(elapsed);
                    }
                },
                .stale => controller.metrics.stale_client_messages += 1,
            }
        }
    };
}
