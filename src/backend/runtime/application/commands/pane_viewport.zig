//! Application command for changing one client's pane viewport.

const AttachmentStore = @import("../../attachment/AttachmentStore.zig");
const SetPaneViewportHandler = @import("SetPaneViewportHandler.zig");
const pane_module = @import("telar-core").pane;
const std = @import("std");

pub const SetPaneViewportResult = enum {
    changed,
    unchanged,
    pane_not_attached,
};

test "SetPaneViewportHandler rejects a pane outside the client attachments" {
    var attachments: AttachmentStore = .{};
    var handler: SetPaneViewportHandler = .{ .attachments = &attachments };

    const result = try handler.execute(.{
        .pane_id = try pane_module(7),
        .offset = 0,
    });

    try std.testing.expectEqual(SetPaneViewportResult.pane_not_attached, result);
}
