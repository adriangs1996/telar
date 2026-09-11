const ReconcileWorkspaceListHandler = @This();
const client_model = @import("../../root.zig").model;
const workspace_list = @import("../../workspace/root.zig").workspace_list;
const source_namespace = @import("workspace_list_snapshot.zig");
model: *client_model.Model,

/// Classifies one decoded domain snapshot without deciding presentation.
///
/// ```zig
/// const outcome = try handler.execute(snapshot);
/// ```
pub fn execute(handler: *ReconcileWorkspaceListHandler, snapshot: workspace_list.SnapshotInput) !source_namespace.Outcome {
    const commit = handler.model.reconcileWorkspaceList(snapshot) catch |err| {
        const rejection = source_namespace.classifyRejection(err) orelse return err;

        return .{ .rejected = rejection };
    };

    return if (commit) |value| .{ .applied = value } else .stale;
}
