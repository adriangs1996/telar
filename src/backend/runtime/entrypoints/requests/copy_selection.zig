//! Protocol controller for copying an attached pane selection to one client.

const GenericCopySelectionController = @import("GenericCopySelectionController.zig").Type;
const CopySelectionStubExecutor = @import("CopySelectionStubExecutor.zig");
const StubClipboard = @import("StubClipboard.zig");
const pane_module = @import("telar-core").pane;
const RuntimeMetrics = @import("../../observability/RuntimeMetrics.zig");
const std = @import("std");
const selection = @import("../../attachment/selection.zig");

const TestController = GenericCopySelectionController(*CopySelectionStubExecutor, *StubClipboard);

test "Controller maps exact coordinates and delivers copied bytes" {
    const pane_id = try pane_module(7);
    var metrics: RuntimeMetrics = .{ .started_ns = 0 };
    var executor: CopySelectionStubExecutor = .{ .bytes = "one\ntwo" };
    var clipboard: StubClipboard = .{};
    var controller = TestController.init(&metrics, &executor, &clipboard);

    controller.copySelection(.{
        .pane_id = pane_id,
        .start_x = 4,
        .start_y = 8,
        .end_x = 2,
        .end_y = 3,
        .linewise = true,
    });

    try std.testing.expectEqual(@as(usize, 1), executor.call_count);
    try std.testing.expectEqual(selection.scratch_bytes, executor.scratch_len);
    try std.testing.expectEqual(pane_id, executor.command.?.pane_id);
    try std.testing.expectEqual(@as(u16, 4), executor.command.?.start_x);
    try std.testing.expectEqual(@as(u32, 8), executor.command.?.start_y);
    try std.testing.expectEqual(@as(u16, 2), executor.command.?.end_x);
    try std.testing.expectEqual(@as(u32, 3), executor.command.?.end_y);
    try std.testing.expect(executor.command.?.linewise);
    try std.testing.expectEqual(@as(usize, 1), clipboard.call_count);
    try std.testing.expectEqual(pane_id, clipboard.pane_id);
    try std.testing.expectEqualStrings("one\ntwo", clipboard.slice());
    try std.testing.expectEqual(@as(u64, 0), metrics.stale_client_messages);
}

test "Controller counts only a missing attachment as stale" {
    var metrics: RuntimeMetrics = .{ .started_ns = 0, .stale_client_messages = 4 };
    var executor: CopySelectionStubExecutor = .{ .outcome = .pane_not_attached };
    var clipboard: StubClipboard = .{};
    var controller = TestController.init(&metrics, &executor, &clipboard);

    controller.copySelection(.{
        .pane_id = try pane_module(7),
        .start_x = 0,
        .start_y = 0,
        .end_x = 0,
        .end_y = 0,
    });

    try std.testing.expectEqual(@as(u64, 5), metrics.stale_client_messages);
    try std.testing.expectEqual(@as(usize, 0), clipboard.call_count);
}

test "Controller preserves clipboard output for unavailable and oversized selections" {
    for ([_]CopySelectionStubExecutor{ .{ .outcome = .unavailable }, .{ .outcome = .too_large } }) |initial| {
        var metrics: RuntimeMetrics = .{ .started_ns = 0, .stale_client_messages = 4 };
        var executor = initial;
        var clipboard: StubClipboard = .{};
        _ = clipboard.setClipboard(try pane_module(3), "pending");
        clipboard.call_count = 0;
        var controller = TestController.init(&metrics, &executor, &clipboard);

        controller.copySelection(.{
            .pane_id = try pane_module(7),
            .start_x = 0,
            .start_y = 0,
            .end_x = 0,
            .end_y = 0,
        });

        try std.testing.expectEqual(@as(u64, 4), metrics.stale_client_messages);
        try std.testing.expectEqual(@as(usize, 0), clipboard.call_count);
        try std.testing.expectEqualStrings("pending", clipboard.slice());
    }
}
