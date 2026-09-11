const RequestTabSnapshotRecoveryHandler = @This();
const Effects = @import("TabSnapshotRecoveryEffects.zig");
const source_namespace = @import("tab_snapshot_recovery.zig");
effects: Effects,

/// Coalesces an existing canonical repair or requests it exactly once.
///
/// ```zig
/// const outcome = try handler.execute(location);
/// ```
pub fn execute(handler: *RequestTabSnapshotRecoveryHandler, location: source_namespace.schema.TabLocation) !source_namespace.Outcome {
    if (handler.effects.pending(handler.effects.context)) {
        return .coalesced;
    }

    try handler.effects.request(handler.effects.context, location);

    return .requested;
}
