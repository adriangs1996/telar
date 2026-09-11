const RecoverPaneAttachmentHandler = @This();
const client_model = @import("../../root.zig").model;
const tab_snapshot_recovery = @import("../tabs/root.zig").tab_snapshot_recovery;
const source_namespace = @import("attach_pane.zig");
model: *const client_model.Model,
snapshots: tab_snapshot_recovery.RequestTabSnapshotRecoveryHandler,

/// Requests canonical membership only while the failed attachment still
/// belongs to the active tab and remains detached.
///
/// ```zig
/// _ = try handler.execute(attachment);
/// ```
pub fn execute(handler: *RecoverPaneAttachmentHandler, attachment: source_namespace.PaneAttachment) !bool {
    if (!handler.model.needsPaneAttachment(attachment)) {
        return false;
    }

    _ = try handler.snapshots.execute(attachment.location);
    return true;
}
