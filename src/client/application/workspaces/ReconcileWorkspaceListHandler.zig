const ModelType = @import("../../model/Model.zig");
const SnapshotInputType = @import("../../workspace/SnapshotInput.zig");
const workspace_list_snapshot = @import("workspace_list_snapshot.zig");
const ReconcileWorkspaceListHandler = @This();

model: *ModelType,

/// Classifies one decoded domain snapshot without deciding presentation.
///
/// ```zig
/// const outcome = try handler.execute(snapshot);
/// ```
pub fn execute(handler: *ReconcileWorkspaceListHandler, snapshot: SnapshotInputType) !workspace_list_snapshot.Outcome {
    const commit = handler.model.reconcileWorkspaceList(snapshot) catch |err| {
        const rejection = workspace_list_snapshot.classifyRejection(err) orelse return err;

        return .{ .rejected = rejection };
    };

    return if (commit) |value| .{ .applied = value } else .stale;
}
