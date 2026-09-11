//! Protocol controller for graphics snapshot recovery. Accepted requests emit
//! no management response; the media lane carries the replacement snapshot.

const GenericRequestGraphicsSnapshotController = @import("GenericRequestGraphicsSnapshotController.zig").Type;
const RequestGraphicsSnapshotStubExecutor = @import("RequestGraphicsSnapshotStubExecutor.zig");
const pane_module = @import("telar-core").pane;
const RuntimeMetrics = @import("../../observability/RuntimeMetrics.zig");
const std = @import("std");

const TestController = GenericRequestGraphicsSnapshotController(*RequestGraphicsSnapshotStubExecutor);

test "Controller maps the exact graphics snapshot pane" {
    const pane_id = try pane_module(7);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var stub: RequestGraphicsSnapshotStubExecutor = .{};
    var controller = TestController.init(&metrics, &stub);

    try controller.requestGraphicsSnapshot(.{ .pane_id = pane_id });

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqual(pane_id, stub.command.?.pane_id);
    try std.testing.expectEqual(@as(u64, 0), metrics.stale_client_messages);
}

test "Controller counts a graphics snapshot for a missing attachment as stale" {
    var metrics: RuntimeMetrics = .{ .started_ns = 0, .stale_client_messages = 4 };
    var stub: RequestGraphicsSnapshotStubExecutor = .{ .result = .pane_not_attached };
    var controller = TestController.init(&metrics, &stub);

    try controller.requestGraphicsSnapshot(.{ .pane_id = try pane_module(7) });

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqual(@as(u64, 5), metrics.stale_client_messages);
}

test "Controller propagates graphics recovery failures without stale accounting" {
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var stub: RequestGraphicsSnapshotStubExecutor = .{ .failure = error.GraphicsRecoveryUnavailable };
    var controller = TestController.init(&metrics, &stub);

    try std.testing.expectError(
        error.GraphicsRecoveryUnavailable,
        controller.requestGraphicsSnapshot(.{ .pane_id = try pane_module(7) }),
    );

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqual(@as(u64, 0), metrics.stale_client_messages);
}
