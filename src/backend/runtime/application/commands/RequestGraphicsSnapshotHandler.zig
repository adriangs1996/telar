const RequestGraphicsSnapshotHandler = @This();
const source_namespace = @import("request_graphics_snapshot.zig");
const RequestGraphicsSnapshot = @import("RequestGraphicsSnapshot.zig");
attachments: *source_namespace.AttachmentStore,

/// Discards one attachment's graphics baseline and schedules a complete
/// replacement. Repeated requests coalesce into the same pending snapshot.
///
/// ```zig
/// const result = try handler.execute(.{ .pane_id = pane_id });
/// ```
pub fn execute(handler: *RequestGraphicsSnapshotHandler, command: RequestGraphicsSnapshot) !source_namespace.RequestGraphicsSnapshotResult {
    if (!handler.attachments.requestGraphicsSnapshot(command.pane_id)) {
        return .pane_not_attached;
    }

    return .requested;
}
