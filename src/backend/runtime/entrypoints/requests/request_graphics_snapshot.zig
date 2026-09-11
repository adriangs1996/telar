//! Protocol controller for graphics snapshot recovery. Accepted requests emit
//! no management response; the media lane carries the replacement snapshot.

const std = @import("std");
const core = @import("telar-core");
const request_graphics_snapshot_commands = @import("../../application/commands/request_graphics_snapshot.zig");
const telemetry_mod = @import("../../observability/root.zig").telemetry;

pub const schema = core.schema;
pub const RuntimeMetrics = telemetry_mod.RuntimeMetrics;

pub const Controller = @import("GenericRequestGraphicsSnapshotController.zig").Type;

const StubExecutor = @import("RequestGraphicsSnapshotStubExecutor.zig");

const TestController = Controller(*StubExecutor);

test "Controller maps the exact graphics snapshot pane" {
    const pane_id = try schema.id.pane(7);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var stub: StubExecutor = .{};
    var controller = TestController.init(&metrics, &stub);

    try controller.requestGraphicsSnapshot(.{ .pane_id = pane_id });

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqual(pane_id, stub.command.?.pane_id);
    try std.testing.expectEqual(@as(u64, 0), metrics.stale_client_messages);
}

test "Controller counts a graphics snapshot for a missing attachment as stale" {
    var metrics: RuntimeMetrics = .{ .started_ns = 0, .stale_client_messages = 4 };
    var stub: StubExecutor = .{ .result = .pane_not_attached };
    var controller = TestController.init(&metrics, &stub);

    try controller.requestGraphicsSnapshot(.{ .pane_id = try schema.id.pane(7) });

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqual(@as(u64, 5), metrics.stale_client_messages);
}

test "Controller propagates graphics recovery failures without stale accounting" {
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var stub: StubExecutor = .{ .failure = error.GraphicsRecoveryUnavailable };
    var controller = TestController.init(&metrics, &stub);

    try std.testing.expectError(
        error.GraphicsRecoveryUnavailable,
        controller.requestGraphicsSnapshot(.{ .pane_id = try schema.id.pane(7) }),
    );

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqual(@as(u64, 0), metrics.stale_client_messages);
}
