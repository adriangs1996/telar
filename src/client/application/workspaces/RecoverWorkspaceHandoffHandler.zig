const WorkspaceRecoveryEffects = @import("WorkspaceRecoveryEffects.zig");
const WorkspaceHandoffFailure = @import("WorkspaceHandoffFailure.zig");
const workspace_handoff = @import("workspace_handoff.zig");
const RecoverWorkspaceHandoffHandler = @This();

effects: WorkspaceRecoveryEffects,

/// Retries the containing workspace only when a remembered pane vanished.
/// Every other failure remains authoritative and is propagated by the
/// dispatcher.
///
/// ```zig
/// const recovery = try handler.execute(failure);
/// ```
pub fn execute(handler: *RecoverWorkspaceHandoffHandler, failure: WorkspaceHandoffFailure) !workspace_handoff.WorkspaceRecovery {
    const workspace = failure.fallback_workspace orelse return .unrecoverable;
    if (failure.code != .pane_not_found) {
        return .unrecoverable;
    }

    handler.effects.forget(handler.effects.context, workspace);
    try handler.effects.retry(handler.effects.context, workspace);

    return .retried;
}
