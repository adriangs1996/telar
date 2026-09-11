const std = @import("std");
const RuntimeMetricsType = @import("../../observability/RuntimeMetrics.zig");
const FrameAckType = @import("telar-core").FrameAck;
const now_module = @import("telar-core").now;
const enabled_module = @import("telar-core").enabled;

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

        io: std.Io,
        metrics: *RuntimeMetricsType,
        executor: Executor,

        /// Creates one controller bound to the requesting client and handler.
        ///
        /// ```zig
        /// var controller = AckController.init(io, &metrics, &handler);
        /// ```
        pub fn init(io: std.Io, metrics: *RuntimeMetricsType, executor: Executor) Self {
            return .{ .io = io, .metrics = metrics, .executor = executor };
        }

        /// Samples receipt time, maps the wire ACK to its application command,
        /// and records stale messages or accepted-frame latency.
        ///
        /// ```zig
        /// try controller.frameAck(ack);
        /// ```
        pub inline fn frameAck(controller: *Self, ack: FrameAckType) !void {
            const result = try controller.executor.execute(.{
                .pane_id = ack.pane_id,
                .frame_id = ack.frame_id,
                .received_at_ns = now_module(controller.io),
            });

            switch (result) {
                .acknowledged => |elapsed| {
                    if (comptime enabled_module) {
                        controller.metrics.ack.observe(elapsed);
                    }
                },
                .stale => controller.metrics.stale_client_messages += 1,
            }
        }
    };
}
