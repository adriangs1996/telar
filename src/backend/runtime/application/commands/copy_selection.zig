//! Application query for copying text from one attached pane.

const AttachmentStore = @import("../../attachment/AttachmentStore.zig");
const CopySelectionHandler = @import("CopySelectionHandler.zig");
const pane_module = @import("telar-core").pane;
const std = @import("std");

pub const CopySelectionResult = union(enum) {
    copied: []const u8,
    pane_not_attached,
    unavailable,
    too_large,
};

test "CopySelectionHandler rejects a pane outside the client attachments" {
    var attachments: AttachmentStore = .{};
    var handler: CopySelectionHandler = .{ .attachments = &attachments };
    var scratch: [32]u8 = undefined;

    const result = handler.execute(.{
        .pane_id = try pane_module(7),
        .start_x = 0,
        .start_y = 0,
        .end_x = 0,
        .end_y = 0,
        .linewise = false,
    }, &scratch);

    try std.testing.expectEqual(std.meta.Tag(CopySelectionResult).pane_not_attached, std.meta.activeTag(result));
}
