const ModelType = @import("../../model/Model.zig");
const WorkspaceSnapshotEffects = @import("WorkspaceSnapshotEffects.zig");
const WorkspaceSnapshotInput = @import("../../workspace/WorkspaceSnapshotInput.zig");
const ApplyWorkspaceSnapshotHandler = @This();

model: *ModelType,
effects: WorkspaceSnapshotEffects,

/// Commits a canonical snapshot before delivering client resources.
/// Model failures have no effects; effect failures preserve the commit.
///
/// ```zig
/// try handler.execute(snapshot);
/// ```
pub fn execute(handler: *ApplyWorkspaceSnapshotHandler, snapshot: WorkspaceSnapshotInput) !void {
    const reconciliation = try handler.model.reconcileWorkspace(snapshot);
    try handler.effects.deliver(handler.effects.context, &reconciliation);
}
