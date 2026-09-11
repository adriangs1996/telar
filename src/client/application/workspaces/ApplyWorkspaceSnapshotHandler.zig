const ApplyWorkspaceSnapshotHandler = @This();
const client_model = @import("../../root.zig").model;
const Effects = @import("WorkspaceSnapshotEffects.zig");
model: *client_model.Model,
effects: Effects,

/// Commits a canonical snapshot before delivering client resources.
/// Model failures have no effects; effect failures preserve the commit.
///
/// ```zig
/// try handler.execute(snapshot);
/// ```
pub fn execute(handler: *ApplyWorkspaceSnapshotHandler, snapshot: client_model.WorkspaceSnapshot) !void {
    const reconciliation = try handler.model.reconcileWorkspace(snapshot);
    try handler.effects.deliver(handler.effects.context, &reconciliation);
}
