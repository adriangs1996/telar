const ModelType = @import("../../model/Model.zig");
const RequestTabSnapshotRecoveryHandlerType = @import("../tabs/RequestTabSnapshotRecoveryHandler.zig");
const PaneAttachmentType = @import("../../model/PaneAttachment.zig");
const RecoverPaneAttachmentHandler = @This();

model: *const ModelType,
snapshots: RequestTabSnapshotRecoveryHandlerType,

/// Requests canonical membership only while the failed attachment still
/// belongs to the active tab and remains detached.
///
/// ```zig
/// _ = try handler.execute(attachment);
/// ```
pub fn execute(handler: *RecoverPaneAttachmentHandler, attachment: PaneAttachmentType) !bool {
    if (!handler.model.needsPaneAttachment(attachment)) {
        return false;
    }

    _ = try handler.snapshots.execute(attachment.location);
    return true;
}
