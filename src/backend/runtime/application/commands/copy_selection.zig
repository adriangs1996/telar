//! Application query for copying text from one attached pane.

const std = @import("std");
const core = @import("telar-core");
const attachment_mod = @import("../../attachment/root.zig");

pub const schema = core.schema;
pub const AttachmentStore = attachment_mod.AttachmentStore;

pub const scratch_bytes = attachment_mod.selection_scratch_bytes;

pub const CopySelection = @import("CopySelection.zig");

pub const CopySelectionResult = union(enum) {
    copied: []const u8,
    pane_not_attached,
    unavailable,
    too_large,
};

pub const CopySelectionHandler = @import("CopySelectionHandler.zig");

test "CopySelectionHandler rejects a pane outside the client attachments" {
    var attachments: AttachmentStore = .{};
    var handler: CopySelectionHandler = .{ .attachments = &attachments };
    var scratch: [32]u8 = undefined;

    const result = handler.execute(.{
        .pane_id = try schema.id.pane(7),
        .start_x = 0,
        .start_y = 0,
        .end_x = 0,
        .end_y = 0,
        .linewise = false,
    }, &scratch);

    try std.testing.expectEqual(std.meta.Tag(CopySelectionResult).pane_not_attached, std.meta.activeTag(result));
}
