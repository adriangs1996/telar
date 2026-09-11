//! Vertical contract tests for the runtime close-pane flow.

const pane_module = @import("telar-core").pane;
const ClosePaneTestPaneCapture = @import("ClosePaneTestPaneCapture.zig");
const ClosePaneHandlerType = @import("../application/commands/ClosePaneHandler.zig");
const ResponseQueueType = @import("../delivery/ResponseQueue.zig");
const ClosePaneController = @import("../entrypoints/requests/ClosePaneController.zig");
const std = @import("std");

test "repeated close requests cross controller and handler idempotently" {
    const pane_id = try pane_module(7);
    var panes: ClosePaneTestPaneCapture = .{ .attached_pane = pane_id };
    var handler: ClosePaneHandlerType = .{ .panes = panes.port() };
    var responses: ResponseQueueType = .{};
    var controller = ClosePaneController.init(&responses, handler.executor());

    try controller.closePane(.{ .request_id = @enumFromInt(41), .pane_id = pane_id });
    try controller.closePane(.{ .request_id = @enumFromInt(42), .pane_id = pane_id });

    try std.testing.expect(panes.requested);
    try std.testing.expect(responses.peek() == null);
}
