//! A client asks for one workspace's snapshot to reconcile its replica.

const core = @import("telar-core");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const client_request = @import("client_request.zig");

/// Queues the workspace snapshot, or `workspace_not_found`.
///
/// ```zig
/// try workspace_reconciliation.snapshot(model, session, request);
/// ```
pub fn snapshot(model: *RuntimeModel, session: *Session, request: core.RequestWorkspaceSnapshot) !void {
    if (!model.workspaces.containsWorkspace(request.workspace)) {
        return client_request.fail(session, request.request_id, .workspace_not_found, "workspace not found");
    }

    try session.delivery.responses.push(.{ .workspace_snapshot = .{
        .request_id = request.request_id,
        .workspace = request.workspace,
    } });
}
