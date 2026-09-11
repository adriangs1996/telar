const WorkspaceIdType = @import("telar-core").WorkspaceId;
const WorkspaceRecoveryEffects = @import("WorkspaceRecoveryEffects.zig");
const RecoveryCapture = @This();

forgotten: ?WorkspaceIdType = null,
retried: ?WorkspaceIdType = null,
fail: bool = false,

pub fn port(capture: *RecoveryCapture) WorkspaceRecoveryEffects {
    return .{ .context = capture, .forget = forget, .retry = retry };
}

fn forget(context: *anyopaque, workspace: WorkspaceIdType) void {
    const capture: *RecoveryCapture = @ptrCast(@alignCast(context));
    capture.forgotten = workspace;
}

fn retry(context: *anyopaque, workspace: WorkspaceIdType) !void {
    const capture: *RecoveryCapture = @ptrCast(@alignCast(context));
    capture.retried = workspace;
    if (capture.fail) {
        return error.RetryFailed;
    }
}
