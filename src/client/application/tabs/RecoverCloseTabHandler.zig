const ModelType = @import("../../model/Model.zig");
const RequestTabSnapshotRecoveryHandlerType = @import("RequestTabSnapshotRecoveryHandler.zig");
const TabLocationType = @import("telar-core").TabLocation;
const std = @import("std");
const RecoverCloseTabHandler = @This();

model: *const ModelType,
snapshots: RequestTabSnapshotRecoveryHandlerType,

/// Restores a rejected close only while its tab remains active.
///
/// ```zig
/// _ = try handler.execute(location);
/// ```
pub fn execute(handler: *RecoverCloseTabHandler, location: TabLocationType) !bool {
    const active = handler.model.activeTabLocation() orelse return false;
    if (!std.meta.eql(active, location)) {
        return false;
    }

    _ = try handler.snapshots.execute(location);
    return true;
}
