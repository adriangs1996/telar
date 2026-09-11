const AttachmentStoreType = @import("../../attachment/AttachmentStore.zig");
const RequestCellSnapshot = @import("RequestCellSnapshot.zig");
const request_snapshot = @import("request_snapshot.zig");
const RequestCellSnapshotHandler = @This();

attachments: *AttachmentStoreType,

/// Marks one attached pane for an unconditional full cell snapshot. The
/// attachment coalesces repeated requests until delivery consumes the mark.
///
/// ```zig
/// const result = try handler.execute(.{ .pane_id = pane_id });
/// ```
pub fn execute(handler: *RequestCellSnapshotHandler, command: RequestCellSnapshot) !request_snapshot.RequestCellSnapshotResult {
    if (!handler.attachments.requestCellSnapshot(command.pane_id)) {
        return .pane_not_attached;
    }

    return .requested;
}
