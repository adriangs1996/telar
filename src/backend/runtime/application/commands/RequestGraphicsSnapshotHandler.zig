const AttachmentStoreType = @import("../../attachment/AttachmentStore.zig");
const RequestGraphicsSnapshot = @import("RequestGraphicsSnapshot.zig");
const request_graphics_snapshot = @import("request_graphics_snapshot.zig");
const RequestGraphicsSnapshotHandler = @This();

attachments: *AttachmentStoreType,

/// Discards one attachment's graphics baseline and schedules a complete
/// replacement. Repeated requests coalesce into the same pending snapshot.
///
/// ```zig
/// const result = try handler.execute(.{ .pane_id = pane_id });
/// ```
pub fn execute(handler: *RequestGraphicsSnapshotHandler, command: RequestGraphicsSnapshot) !request_graphics_snapshot.RequestGraphicsSnapshotResult {
    if (!handler.attachments.requestGraphicsSnapshot(command.pane_id)) {
        return .pane_not_attached;
    }

    return .requested;
}
