//! Request-scoped controller for the detach-pane protocol message.

const pane_module = @import("telar-core").pane;
const Capture = @import("Capture.zig");
const DetachPaneController = @import("DetachPaneController.zig");
const std = @import("std");

test "Controller maps detach-pane requests without a success response" {
    const pane_id = try pane_module(7);
    var capture: Capture = .{ .result = .detached };
    var controller = DetachPaneController.init(capture.executor(), capture.staleMessages());

    try controller.detachPane(.{ .pane_id = pane_id });

    try std.testing.expectEqual(@as(usize, 1), capture.command_count);
    try std.testing.expectEqual(pane_id, capture.pane_id);
    try std.testing.expectEqual(@as(usize, 0), capture.stale_count);
}

test "Controller records one stale message for a missing attachment" {
    var capture: Capture = .{ .result = .not_attached };
    var controller = DetachPaneController.init(capture.executor(), capture.staleMessages());

    try controller.detachPane(.{ .pane_id = try pane_module(7) });

    try std.testing.expectEqual(@as(usize, 1), capture.command_count);
    try std.testing.expectEqual(@as(usize, 1), capture.stale_count);
}

test "Controller propagates unexpected detach failures without recording stale input" {
    var capture: Capture = .{
        .result = .detached,
        .failure = error.AttachmentStateConflict,
    };
    var controller = DetachPaneController.init(capture.executor(), capture.staleMessages());

    try std.testing.expectError(error.AttachmentStateConflict, controller.detachPane(.{
        .pane_id = try pane_module(7),
    }));

    try std.testing.expectEqual(@as(usize, 1), capture.command_count);
    try std.testing.expectEqual(@as(usize, 0), capture.stale_count);
}
