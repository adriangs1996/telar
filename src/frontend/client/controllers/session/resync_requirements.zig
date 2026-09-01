//! Adapts runtime resynchronization requirements to client application policy.

const core = @import("telar-core");
const session_application = @import("../../application/session/root.zig");

const Client = @import("../../client.zig");
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const workspace_handoffs = @import("../workspaces/workspace_handoffs.zig");
const resync_required = session_application.resync_required;
const schema = core.schema;

/// Resolves disposable client state and applies one validated runtime resync.
/// The client loop maps only the returned `exit` outcome to process status.
///
/// ```zig
/// const outcome = try apply(client, required);
/// ```
pub fn apply(client: *Client, required: schema.ResyncRequired) !resync_required.Outcome {
    var use_case = handler(client);

    return use_case.execute(if (required.workspace_closed)
        .{ .workspace_closed = .{
            .workspace = required.workspace,
            .previous_workspace = required.previous_workspace,
        } }
    else
        .{ .reconcile = .{
            .required_workspace = required.workspace,
            .projected_workspace = client.model.workspaceLocation(),
            .snapshot_pending = request_lifecycle.has(client, .workspace_snapshot),
        } });
}

fn handler(client: *Client) resync_required.HandleResyncRequiredHandler {
    return .{ .effects = .{
        .context = client,
        .forget_workspace = forgetWorkspace,
        .request_snapshot = requestSnapshot,
        .request_handoff = requestHandoff,
    } };
}

fn forgetWorkspace(context: *anyopaque, workspace: schema.WorkspaceLocation) void {
    const client: *Client = @ptrCast(@alignCast(context));

    client.navigation_history.forget(workspace);
}

fn requestSnapshot(context: *anyopaque, workspace: schema.WorkspaceLocation) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try request_lifecycle.requestWorkspaceSnapshot(client, workspace);
}

fn requestHandoff(context: *anyopaque, workspace: schema.WorkspaceId) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    _ = try workspace_handoffs.requestWorkspace(client, workspace);
}
