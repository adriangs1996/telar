//! Protocol controller for pane frame acknowledgements. ACKs have no direct
//! response; accepting one permits the cell lane to compute its next patch.

const GenericFrameAckController = @import("GenericFrameAckController.zig").Type;
const FrameAckStubExecutor = @import("FrameAckStubExecutor.zig");
const pane_module = @import("telar-core").pane;
const RuntimeMetrics = @import("../../observability/RuntimeMetrics.zig");
const std = @import("std");
const now_module = @import("telar-core").now;
const enabled_module = @import("telar-core").enabled;

const TestController = GenericFrameAckController(*FrameAckStubExecutor);

test "Controller maps an exact ACK and records accepted-frame latency" {
    const pane_id = try pane_module(7);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var stub: FrameAckStubExecutor = .{ .result = .{ .acknowledged = 37 } };
    var controller = TestController.init(std.testing.io, &metrics, &stub);
    const before = now_module(std.testing.io);

    try controller.frameAck(.{ .pane_id = pane_id, .frame_id = 11 });

    const after = now_module(std.testing.io);
    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqual(pane_id, stub.command.?.pane_id);
    try std.testing.expectEqual(@as(u64, 11), stub.command.?.frame_id);
    try std.testing.expect(stub.command.?.received_at_ns >= before);
    try std.testing.expect(stub.command.?.received_at_ns <= after);
    try std.testing.expectEqual(@as(u64, if (enabled_module) 1 else 0), metrics.ack.count);
    try std.testing.expectEqual(@as(u64, if (enabled_module) 37 else 0), metrics.ack.total_ns);
    try std.testing.expectEqual(@as(u64, if (enabled_module) 37 else 0), metrics.ack.max_ns);
    try std.testing.expectEqual(@as(u64, 0), metrics.stale_client_messages);
}

test "Controller counts a rejected ACK as one stale client message" {
    var metrics: RuntimeMetrics = .{ .started_ns = 0, .stale_client_messages = 4 };
    var stub: FrameAckStubExecutor = .{ .result = .stale };
    var controller = TestController.init(std.testing.io, &metrics, &stub);

    try controller.frameAck(.{
        .pane_id = try pane_module(7),
        .frame_id = 11,
    });

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqual(@as(u64, 5), metrics.stale_client_messages);
    try std.testing.expectEqual(@as(u64, 0), metrics.ack.count);
}

test "Controller propagates ACK infrastructure failures without changing metrics" {
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var stub: FrameAckStubExecutor = .{ .failure = error.AcknowledgementUnavailable };
    var controller = TestController.init(std.testing.io, &metrics, &stub);

    try std.testing.expectError(error.AcknowledgementUnavailable, controller.frameAck(.{
        .pane_id = try pane_module(7),
        .frame_id = 11,
    }));

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqual(@as(u64, 0), metrics.stale_client_messages);
    try std.testing.expectEqual(@as(u64, 0), metrics.ack.count);
}
