//! A client's copy-mode selection is read from the pane's retained cells
//! and returned as its clipboard.

const core = @import("telar-core");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const selection = @import("attachment/selection.zig");
const limit_reached = @import("limit_reached.zig");

/// Extracts the selected text and queues it for the client's clipboard. A
/// selection larger than the clipboard bound copies nothing and reports the
/// bound.
///
/// ```zig
/// try copy_mode.copy(model, session, request);
/// ```
pub fn copy(model: *RuntimeModel, session: *Session, request: core.CopySelection) !void {
    const attachment = model.attachments.find(session.slot, request.pane_id) orelse {
        model.metrics.stale_client_messages += 1;
        return;
    };

    const scratch = try model.gpa.alloc(u8, selection.scratch_bytes);
    defer model.gpa.free(scratch);
    const result = attachment.copySelection(
        .{
            .start_x = request.start_x,
            .start_y = request.start_y,
            .end_x = request.end_x,
            .end_y = request.end_y,
            .linewise = request.linewise,
        },
        scratch,
    );

    switch (result) {
        .copied => |bytes| try session.delivery.setClipboard(model.gpa, request.pane_id, bytes),
        .unavailable => {},
        .too_large => limit_reached.report(model, .{
            .limit = selection.clipboard_limit,
        }),
    }
}
