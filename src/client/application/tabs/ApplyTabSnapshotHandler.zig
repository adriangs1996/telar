const ApplyTabSnapshotHandler = @This();
const client_model = @import("../../root.zig").model;
const source_namespace = @import("tab_snapshot.zig");
const Effects = @import("TabSnapshotEffects.zig");
model: *client_model.Model,
area: source_namespace.ui.Rect,
effects: Effects,

/// Commits canonical pane membership before delivering client resources.
/// Model failures have no effects; effect failures preserve the commit.
///
/// ```zig
/// try handler.execute(snapshot);
/// ```
pub fn execute(handler: *ApplyTabSnapshotHandler, snapshot: client_model.TabSnapshot) !void {
    const reconciliation = try handler.model.reconcileTab(snapshot, handler.area);
    try handler.effects.deliver(handler.effects.context, &reconciliation);
}
