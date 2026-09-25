//! A client's copy-mode selection is read from the pane's retained cells
//! and returned as its clipboard.

const core = @import("telar-core");
const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const selection = @import("attachment/selection.zig");

/// Extracts the selected text and queues it for the client's clipboard.
///
/// ```zig
/// copy_mode.copy(model, session, request);
/// ```
pub fn copy(model: *RuntimeModel, session: *Session, request: core.CopySelection) void {
    const attachment = model.attachments.find(session.slot, request.pane_id) orelse {
        model.metrics.stale_client_messages += 1;
        return;
    };

    var scratch: [selection.scratch_bytes]u8 = undefined;
    const result = attachment.copySelection(
        .{
            .start_x = request.start_x,
            .start_y = request.start_y,
            .end_x = request.end_x,
            .end_y = request.end_y,
            .linewise = request.linewise,
        },
        &scratch,
    );

    switch (result) {
        .copied => |bytes| {
            const accepted = session.delivery.setClipboard(request.pane_id, bytes);
            std.debug.assert(accepted);
        },
        .unavailable, .too_large => {},
    }
}
