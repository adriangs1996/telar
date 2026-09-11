const RecoverCloseTabHandler = @This();
const client_model = @import("../../root.zig").model;
const tab_snapshot_recovery = @import("tab_snapshot_recovery.zig");
const source_namespace = @import("close_tab.zig");
const std = @import("std");
model: *const client_model.Model,
snapshots: tab_snapshot_recovery.RequestTabSnapshotRecoveryHandler,

/// Restores a rejected close only while its tab remains active.
///
/// ```zig
/// _ = try handler.execute(location);
/// ```
pub fn execute(handler: *RecoverCloseTabHandler, location: source_namespace.schema.TabLocation) !bool {
    const active = handler.model.activeTabLocation() orelse return false;
    if (!std.meta.eql(active, location)) {
        return false;
    }

    _ = try handler.snapshots.execute(location);
    return true;
}
