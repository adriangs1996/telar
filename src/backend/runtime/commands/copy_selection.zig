//! Application query for copying text from one attached pane.

const std = @import("std");
const core = @import("telar-core");
const attachment_mod = @import("../attachment.zig");

const schema = core.schema;
const AttachmentStore = attachment_mod.AttachmentStore;

pub const scratch_bytes = attachment_mod.selection_scratch_bytes;

pub const CopySelection = struct {
    pane_id: schema.PaneId,
    start_x: u16,
    start_y: u32,
    end_x: u16,
    end_y: u32,
    linewise: bool,
};

pub const CopySelectionResult = union(enum) {
    copied: []const u8,
    pane_not_attached,
    unavailable,
    too_large,
};

pub const CopySelectionHandler = struct {
    attachments: *AttachmentStore,

    /// Resolves attachment authority and extracts the requested inclusive
    /// range into caller-owned scratch storage. Copied bytes borrow `scratch`
    /// and must be consumed before the next use of that storage.
    ///
    /// ```zig
    /// const result = handler.execute(command, &scratch);
    /// ```
    pub fn execute(handler: *CopySelectionHandler, command: CopySelection, scratch: []u8) CopySelectionResult {
        const result = handler.attachments.copySelection(command.pane_id, .{
            .range = .{
                .start_x = command.start_x,
                .start_y = command.start_y,
                .end_x = command.end_x,
                .end_y = command.end_y,
                .linewise = command.linewise,
            },
            .scratch = scratch,
        }) orelse return .pane_not_attached;

        return switch (result) {
            .copied => |bytes| .{ .copied = bytes },
            .unavailable => .unavailable,
            .too_large => .too_large,
        };
    }
};

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
