//! Protocol controller for pane resize messages.

const GenericPaneResizeController = @import("GenericPaneResizeController.zig").Type;
const PaneResizeStubExecutor = @import("PaneResizeStubExecutor.zig");
const pane_module = @import("telar-core").pane;
const TerminalSizeType = @import("telar-core").TerminalSize;
const RuntimeMetrics = @import("../../observability/RuntimeMetrics.zig");
const std = @import("std");
const pane_resize_commands = @import("../../application/commands/pane_resize.zig");

const TestController = GenericPaneResizeController(*PaneResizeStubExecutor);

test "Controller forwards the exact pane resize" {
    const pane_id = try pane_module(7);
    const size: TerminalSizeType = .{ .cols = 80, .rows = 24, .cell_width_px = 8, .cell_height_px = 16 };
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var stub: PaneResizeStubExecutor = .{};
    var controller = TestController.init(&metrics, &stub);

    try controller.paneResize(.{ .pane_id = pane_id, .size = size });

    try std.testing.expectEqual(@as(usize, 1), stub.call_count);
    try std.testing.expectEqual(pane_id, stub.command.?.pane_id);
    try std.testing.expectEqualDeep(size, stub.command.?.size);
    try std.testing.expectEqual(@as(u64, 0), metrics.stale_client_messages);
    try std.testing.expectEqual(@as(u64, 0), metrics.geometry_rejections);
}

test "Controller accounts for resize policy rejections" {
    const pane_id = try pane_module(7);

    for ([_]pane_resize_commands.PaneResizeResult{ .pane_not_attached, .geometry_rejected }) |result| {
        var metrics: RuntimeMetrics = .{
            .started_ns = 0,
            .stale_client_messages = 3,
            .geometry_rejections = 5,
        };
        var stub: PaneResizeStubExecutor = .{ .result = result };
        var controller = TestController.init(&metrics, &stub);

        try controller.paneResize(.{
            .pane_id = pane_id,
            .size = .{ .cols = 80, .rows = 24 },
        });

        try std.testing.expectEqual(@as(usize, 1), stub.call_count);
        try std.testing.expectEqual(@as(u64, if (result == .pane_not_attached) 4 else 3), metrics.stale_client_messages);
        try std.testing.expectEqual(@as(u64, if (result == .geometry_rejected) 6 else 5), metrics.geometry_rejections);
    }
}

test "Controller propagates resize infrastructure failures regardless of their names" {
    const pane_id = try pane_module(7);

    for ([_]anyerror{ error.ResizeSchedulerUnavailable, error.PaneNotAttached, error.GeometryRejected }) |failure| {
        var metrics: RuntimeMetrics = .{ .started_ns = 0 };
        var stub: PaneResizeStubExecutor = .{ .failure = failure };
        var controller = TestController.init(&metrics, &stub);

        try std.testing.expectError(failure, controller.paneResize(.{
            .pane_id = pane_id,
            .size = .{ .cols = 80, .rows = 24 },
        }));

        try std.testing.expectEqual(@as(usize, 1), stub.call_count);
        try std.testing.expectEqual(@as(u64, 0), metrics.stale_client_messages);
        try std.testing.expectEqual(@as(u64, 0), metrics.geometry_rejections);
    }
}
