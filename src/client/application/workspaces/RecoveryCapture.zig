const RecoveryCapture = @This();
const source_namespace = @import("workspace_handoff.zig");
const WorkspaceRecoveryEffects = @import("WorkspaceRecoveryEffects.zig");
forgotten: ?source_namespace.schema.WorkspaceId = null,
retried: ?source_namespace.schema.WorkspaceId = null,
fail: bool = false,

pub fn port(capture: *RecoveryCapture) WorkspaceRecoveryEffects {
    return .{ .context = capture, .forget = forget, .retry = retry };
}

fn forget(context: *anyopaque, workspace: source_namespace.schema.WorkspaceId) void {
    const capture: *RecoveryCapture = @ptrCast(@alignCast(context));
    capture.forgotten = workspace;
}

fn retry(context: *anyopaque, workspace: source_namespace.schema.WorkspaceId) !void {
    const capture: *RecoveryCapture = @ptrCast(@alignCast(context));
    capture.retried = workspace;
    if (capture.fail) {
        return error.RetryFailed;
    }
}
