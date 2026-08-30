//! Application command for returning graphics transfer capacity to one client
//! attachment.

const std = @import("std");
const core = @import("telar-core");
const attachment_mod = @import("../attachment.zig");

const schema = core.schema;
const AttachmentStore = attachment_mod.AttachmentStore;

pub const ReturnGraphicsCredit = struct {
    pane_id: schema.PaneId,
    bytes: u64,
};

pub const ReturnGraphicsCreditResult = enum {
    returned,
    pane_not_attached,
    invalid_amount,
};

pub const ReturnGraphicsCreditHandler = struct {
    attachments: *AttachmentStore,

    /// Returns only bytes previously consumed by one attachment. The aggregate
    /// rejects over-returned or unrepresentable amounts without changing credit.
    ///
    /// ```zig
    /// const result = try handler.execute(.{ .pane_id = pane_id, .bytes = 4096 });
    /// ```
    pub fn execute(handler: *ReturnGraphicsCreditHandler, command: ReturnGraphicsCredit) !ReturnGraphicsCreditResult {
        return switch (handler.attachments.returnGraphicsCredit(.{
            .pane_id = command.pane_id,
            .bytes = command.bytes,
        })) {
            .returned => .returned,
            .pane_not_attached => .pane_not_attached,
            .invalid_amount => .invalid_amount,
        };
    }
};

test "ReturnGraphicsCreditHandler rejects a pane outside the client attachments" {
    var attachments: AttachmentStore = .{};
    var handler: ReturnGraphicsCreditHandler = .{ .attachments = &attachments };

    const result = try handler.execute(.{
        .pane_id = try schema.id.pane(7),
        .bytes = 1,
    });

    try std.testing.expectEqual(ReturnGraphicsCreditResult.pane_not_attached, result);
}
