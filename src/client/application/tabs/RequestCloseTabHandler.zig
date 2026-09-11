const ModelType = @import("../../model/Model.zig");
const CloseTabOperationGate = @import("CloseTabOperationGate.zig");
const PrepareTabCloseHandlerType = @import("PrepareTabCloseHandler.zig");
const RequestTabSnapshotRecoveryHandlerType = @import("RequestTabSnapshotRecoveryHandler.zig");
const CloseRequestEffects = @import("CloseRequestEffects.zig");
const RequestCloseTabHandler = @This();

model: *const ModelType,
gate: CloseTabOperationGate,
preparation: PrepareTabCloseHandlerType,
snapshots: RequestTabSnapshotRecoveryHandlerType,
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
