const RequestCloseTabHandler = @This();
const client_model = @import("../../root.zig").model;
const TabOperationGate = @import("CloseTabTabOperationGate.zig");
const tab_close_preparation = @import("tab_close_preparation.zig");
const tab_snapshot_recovery = @import("tab_snapshot_recovery.zig");
const CloseRequestEffects = @import("CloseRequestEffects.zig");
model: *const client_model.Model,
gate: TabOperationGate,
preparation: tab_close_preparation.PrepareTabCloseHandler,
snapshots: tab_snapshot_recovery.RequestTabSnapshotRecoveryHandler,
effects: CloseRequestEffects,

/// Verifies delivery capacity, detaches the active tab and sends one close
/// intent. A failure after detachment requests canonical restoration.
///
/// ```zig
/// if (!try handler.execute()) {
///     return;
/// }
/// ```
pub fn execute(handler: *RequestCloseTabHandler) !bool {
    if (handler.gate.pending(handler.gate.context)) {
        return false;
    }

    const location = handler.model.activeTabLocation() orelse return false;

    try handler.preparation.execute(handler.model, location);
    handler.effects.detach(handler.effects.context, location) catch |err| {
        _ = handler.snapshots.execute(location) catch |restore_err| {
            return restore_err;
        };
        return err;
    };

    handler.effects.send(handler.effects.context, .{ .location = location }) catch |err| {
        _ = handler.snapshots.execute(location) catch |restore_err| {
            return restore_err;
        };
        return err;
    };

    return true;
}
