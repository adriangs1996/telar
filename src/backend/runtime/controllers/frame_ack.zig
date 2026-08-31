//! Protocol controller for pane frame acknowledgements. ACKs have no direct
//! response; accepting one permits the cell lane to compute its next patch.

const std = @import("std");
const core = @import("telar-core");
const frame_ack_commands = @import("../commands/frame_ack.zig");
const telemetry_mod = @import("../observability/root.zig").telemetry;

const Io = std.Io;
const schema = core.schema;
const diagnostics = core.diagnostics;
const RuntimeMetrics = telemetry_mod.RuntimeMetrics;

/// Builds a statically dispatched acknowledgement controller for the cell
/// delivery path.
///
/// ```zig
/// const AckController = Controller(*frame_ack_commands.FrameAckHandler);
/// var controller = AckController.init(io, &metrics, &handler);
/// ```
pub fn Controller(comptime Executor: type) type {
    return struct {
        const Self = @This();

        io: Io,
        metrics: *RuntimeMetrics,
        executor: Executor,

        /// Creates one controller bound to the requesting client and handler.
        ///
        /// ```zig
        /// var controller = AckController.init(io, &metrics, &handler);
        /// ```
        pub fn init(io: Io, metrics: *RuntimeMetrics, executor: Executor) Self {
            return .{ .io = io, .metrics = metrics, .executor = executor };
        }

        /// Samples receipt time, maps the wire ACK to its application command,
        /// and records stale messages or accepted-frame latency.
        ///
        /// ```zig
        /// try controller.frameAck(ack);
        /// ```
        pub inline fn frameAck(controller: *Self, ack: schema.FrameAck) !void {
            const result = try controller.executor.execute(.{
                .pane_id = ack.pane_id,
                .frame_id = ack.frame_id,
                .received_at_ns = diagnostics.now(controller.io),
            });

            switch (result) {
                .acknowledged => |elapsed| {
                    if (comptime diagnostics.enabled) {
                        controller.metrics.ack.observe(elapsed);
                    }
                },
                .stale => controller.metrics.stale_client_messages += 1,
            }
        }
    };
}

const StubExecutor = struct {
    result: frame_ack_commands.FrameAckResult = .{ .acknowledged = 0 },
    failure: ?anyerror = null,
    call_count: usize = 0,
    command: ?frame_ack_commands.AcknowledgeFrame = null,

    fn execute(stub: *StubExecutor, command: frame_ack_commands.AcknowledgeFrame) !frame_ack_commands.FrameAckResult {
        stub.call_count += 1;
        stub.command = command;

        if (stub.failure) |failure| {
            return failure;
        }

        return stub.result;
    }
};

const TestController = Controller(*StubExecutor);

test "Controller maps an exact ACK and records accepted-frame latency" {
    const pane_id = try schema.id.pane(7);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var stub: StubExecutor = .{ .result = .{ .acknowledged = 37 } };
    var controller = TestController.init(std.testing.io, &metrics, &stub);
    const before = diagnostics.now(std.testing.io);

    try controller.frameAck(.{ .pane_id = pane_id, .frame_id = 11 });

    const after = diagnostics.now(std.testing.io);
    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqual(pane_id, stub.command.?.pane_id);
    try std.testing.expectEqual(@as(u64, 11), stub.command.?.frame_id);
    try std.testing.expect(stub.command.?.received_at_ns >= before);
    try std.testing.expect(stub.command.?.received_at_ns <= after);
    try std.testing.expectEqual(@as(u64, if (diagnostics.enabled) 1 else 0), metrics.ack.count);
    try std.testing.expectEqual(@as(u64, if (diagnostics.enabled) 37 else 0), metrics.ack.total_ns);
    try std.testing.expectEqual(@as(u64, if (diagnostics.enabled) 37 else 0), metrics.ack.max_ns);
    try std.testing.expectEqual(@as(u64, 0), metrics.stale_client_messages);
}

test "Controller counts a rejected ACK as one stale client message" {
    var metrics: RuntimeMetrics = .{ .started_ns = 0, .stale_client_messages = 4 };
    var stub: StubExecutor = .{ .result = .stale };
    var controller = TestController.init(std.testing.io, &metrics, &stub);

    try controller.frameAck(.{
        .pane_id = try schema.id.pane(7),
        .frame_id = 11,
    });

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqual(@as(u64, 5), metrics.stale_client_messages);
    try std.testing.expectEqual(@as(u64, 0), metrics.ack.count);
}

test "Controller propagates ACK infrastructure failures without changing metrics" {
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var stub: StubExecutor = .{ .failure = error.AcknowledgementUnavailable };
    var controller = TestController.init(std.testing.io, &metrics, &stub);

    try std.testing.expectError(error.AcknowledgementUnavailable, controller.frameAck(.{
        .pane_id = try schema.id.pane(7),
        .frame_id = 11,
    }));

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqual(@as(u64, 0), metrics.stale_client_messages);
    try std.testing.expectEqual(@as(u64, 0), metrics.ack.count);
}
