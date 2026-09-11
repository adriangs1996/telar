//! Application command for returning graphics transfer capacity to one client
//! attachment.

const std = @import("std");
const core = @import("telar-core");
const attachment_mod = @import("../../attachment/root.zig");

pub const schema = core.schema;
pub const AttachmentStore = attachment_mod.AttachmentStore;

pub const ReturnGraphicsCredit = @import("ReturnGraphicsCredit.zig");

pub const ReturnGraphicsCreditResult = enum {
    returned,
    pane_not_attached,
    invalid_amount,
};

pub const ReturnGraphicsCreditHandler = @import("ReturnGraphicsCreditHandler.zig");

test "ReturnGraphicsCreditHandler rejects a pane outside the client attachments" {
    var attachments: AttachmentStore = .{};
    var handler: ReturnGraphicsCreditHandler = .{ .attachments = &attachments };

    const result = try handler.execute(.{
        .pane_id = try schema.id.pane(7),
        .bytes = 1,
    });

    try std.testing.expectEqual(ReturnGraphicsCreditResult.pane_not_attached, result);
}
