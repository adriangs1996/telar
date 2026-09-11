//! Application command for changing one client's pane viewport.

const std = @import("std");
const core = @import("telar-core");
const attachment_mod = @import("../../attachment/root.zig");

pub const schema = core.schema;
pub const AttachmentStore = attachment_mod.AttachmentStore;

pub const SetPaneViewport = @import("SetPaneViewport.zig");

pub const SetPaneViewportResult = enum {
    changed,
    unchanged,
    pane_not_attached,
};

pub const SetPaneViewportHandler = @import("SetPaneViewportHandler.zig");

test "SetPaneViewportHandler rejects a pane outside the client attachments" {
    var attachments: AttachmentStore = .{};
    var handler: SetPaneViewportHandler = .{ .attachments = &attachments };

    const result = try handler.execute(.{
        .pane_id = try schema.id.pane(7),
        .offset = 0,
    });

    try std.testing.expectEqual(SetPaneViewportResult.pane_not_attached, result);
}
