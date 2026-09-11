const ModelType = @import("../../model/Model.zig");
const RectType = @import("telar-core").Rect;
const TabSnapshotEffects = @import("TabSnapshotEffects.zig");
const PaneSnapshot = @import("../../workspace/PaneSnapshot.zig");
const ApplyTabSnapshotHandler = @This();

model: *ModelType,
area: RectType,
effects: TabSnapshotEffects,

/// Commits canonical pane membership before delivering client resources.
/// Model failures have no effects; effect failures preserve the commit.
///
/// ```zig
/// try handler.execute(snapshot);
/// ```
pub fn execute(handler: *ApplyTabSnapshotHandler, snapshot: PaneSnapshot) !void {
    const reconciliation = try handler.model.reconcileTab(snapshot, handler.area);
    try handler.effects.deliver(handler.effects.context, &reconciliation);
}
