//! Application command for returning graphics transfer capacity to one client
//! attachment.

const AttachmentStore = @import("../../attachment/AttachmentStore.zig");
const ReturnGraphicsCreditHandler = @import("ReturnGraphicsCreditHandler.zig");
const pane_module = @import("telar-core").pane;
const std = @import("std");

pub const ReturnGraphicsCreditResult = enum {
    returned,
    pane_not_attached,
    invalid_amount,
};

test "ReturnGraphicsCreditHandler rejects a pane outside the client attachments" {
    var attachments: AttachmentStore = .{};
    var handler: ReturnGraphicsCreditHandler = .{ .attachments = &attachments };

    const result = try handler.execute(.{
        .pane_id = try pane_module(7),
        .bytes = 1,
    });

    try std.testing.expectEqual(ReturnGraphicsCreditResult.pane_not_attached, result);
}
