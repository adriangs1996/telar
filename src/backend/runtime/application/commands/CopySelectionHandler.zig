const AttachmentStoreType = @import("../../attachment/AttachmentStore.zig");
const CopySelection = @import("CopySelection.zig");
const copy_selection = @import("copy_selection.zig");
const CopySelectionHandler = @This();

attachments: *AttachmentStoreType,

/// Resolves attachment authority and extracts the requested inclusive
/// range into caller-owned scratch storage. Copied bytes borrow `scratch`
/// and must be consumed before the next use of that storage.
///
/// ```zig
/// const result = handler.execute(command, &scratch);
/// ```
pub fn execute(handler: *CopySelectionHandler, command: CopySelection, scratch: []u8) copy_selection.CopySelectionResult {
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
