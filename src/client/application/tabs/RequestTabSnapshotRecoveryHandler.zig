const TabSnapshotRecoveryEffects = @import("TabSnapshotRecoveryEffects.zig");
const TabLocationType = @import("telar-core").TabLocation;
const tab_snapshot_recovery = @import("tab_snapshot_recovery.zig");
const RequestTabSnapshotRecoveryHandler = @This();

effects: TabSnapshotRecoveryEffects,

/// Coalesces an existing canonical repair or requests it exactly once.
///
/// ```zig
/// const outcome = try handler.execute(location);
/// ```
pub fn execute(handler: *RequestTabSnapshotRecoveryHandler, location: TabLocationType) !tab_snapshot_recovery.Outcome {
    if (handler.effects.pending(handler.effects.context)) {
        return .coalesced;
    }

    try handler.effects.request(handler.effects.context, location);

    return .requested;
}
