//! Protocol controller for pane frame acknowledgements. ACKs have no direct
//! response; accepting one permits the cell lane to compute its next patch.

const std = @import("std");
const core = @import("telar-core");
const frame_ack_commands = @import("../../application/commands/frame_ack.zig");
const telemetry_mod = @import("../../observability/root.zig").telemetry;

pub const Io = std.Io;
pub const schema = core.schema;
pub const diagnostics = core.diagnostics;
pub const RuntimeMetrics = telemetry_mod.RuntimeMetrics;

pub const Controller = @import("GenericFrameAckController.zig").Type;

const StubExecutor = @import("FrameAckStubExecutor.zig");

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
