//! Request-scoped controller for the detach-pane protocol message.

const std = @import("std");
const core = @import("telar-core");
const detach_pane_commands = @import("../../application/commands/detach_pane.zig");

pub const schema = core.schema;

pub const StaleMessages = @import("StaleMessages.zig");

pub const Controller = @import("DetachPaneController.zig");

const Capture = @import("Capture.zig");

test "Controller maps detach-pane requests without a success response" {
    const pane_id = try schema.id.pane(7);
    var capture: Capture = .{ .result = .detached };
    var controller = Controller.init(capture.executor(), capture.staleMessages());

    try controller.detachPane(.{ .pane_id = pane_id });

    try std.testing.expectEqual(@as(usize, 1), capture.command_count);
    try std.testing.expectEqual(pane_id, capture.pane_id);
    try std.testing.expectEqual(@as(usize, 0), capture.stale_count);
}

test "Controller records one stale message for a missing attachment" {
    var capture: Capture = .{ .result = .not_attached };
    var controller = Controller.init(capture.executor(), capture.staleMessages());

    try controller.detachPane(.{ .pane_id = try schema.id.pane(7) });

    try std.testing.expectEqual(@as(usize, 1), capture.command_count);
    try std.testing.expectEqual(@as(usize, 1), capture.stale_count);
}

test "Controller propagates unexpected detach failures without recording stale input" {
    var capture: Capture = .{
        .result = .detached,
        .failure = error.AttachmentStateConflict,
    };
    var controller = Controller.init(capture.executor(), capture.staleMessages());

    try std.testing.expectError(error.AttachmentStateConflict, controller.detachPane(.{
        .pane_id = try schema.id.pane(7),
    }));

    try std.testing.expectEqual(@as(usize, 1), capture.command_count);
    try std.testing.expectEqual(@as(usize, 0), capture.stale_count);
}
