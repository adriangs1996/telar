const RequestCellSnapshotHandler = @This();
const source_namespace = @import("request_snapshot.zig");
const RequestCellSnapshot = @import("RequestCellSnapshot.zig");
attachments: *source_namespace.AttachmentStore,

/// Marks one attached pane for an unconditional full cell snapshot. The
/// attachment coalesces repeated requests until delivery consumes the mark.
///
/// ```zig
/// const result = try handler.execute(.{ .pane_id = pane_id });
/// ```
pub fn execute(handler: *RequestCellSnapshotHandler, command: RequestCellSnapshot) !source_namespace.RequestCellSnapshotResult {
    if (!handler.attachments.requestCellSnapshot(command.pane_id)) {
        return .pane_not_attached;
    }

    return .requested;
}
