const RecoverWorkspaceHandoffHandler = @This();
const WorkspaceRecoveryEffects = @import("WorkspaceRecoveryEffects.zig");
const WorkspaceHandoffFailure = @import("WorkspaceHandoffFailure.zig");
const source_namespace = @import("workspace_handoff.zig");
effects: WorkspaceRecoveryEffects,

/// Retries the containing workspace only when a remembered pane vanished.
/// Every other failure remains authoritative and is propagated by the
/// dispatcher.
///
/// ```zig
/// const recovery = try handler.execute(failure);
/// ```
pub fn execute(handler: *RecoverWorkspaceHandoffHandler, failure: WorkspaceHandoffFailure) !source_namespace.WorkspaceRecovery {
    const workspace = failure.fallback_workspace orelse return .unrecoverable;
    if (failure.code != .pane_not_found) {
        return .unrecoverable;
    }

    handler.effects.forget(handler.effects.context, workspace);
    try handler.effects.retry(handler.effects.context, workspace);

    return .retried;
}
