//! Adapts runtime resynchronization requirements to client application policy.

const Client = @import("../../AttachedClient.zig");
const ResyncRequiredType = @import("telar-core").ResyncRequired;
const ApplicationSessionResyncRequiredOutcome = @import("../../application/session/resync_required.zig").Outcome;
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const HandleResyncRequiredHandlerType = @import("../../application/session/HandleResyncRequiredHandler.zig");
const WorkspaceLocationType = @import("telar-core").WorkspaceLocation;
const WorkspaceIdType = @import("telar-core").WorkspaceId;
const workspace_handoffs = @import("../workspaces/workspace_handoffs.zig");

/// Resolves disposable client state and applies one validated runtime resync.
/// The client loop maps only the returned `exit` outcome to process status.
///
/// ```zig
/// const outcome = try apply(client, required);
/// ```
pub fn apply(client: *Client, required: ResyncRequiredType) !ApplicationSessionResyncRequiredOutcome {
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

fn handler(client: *Client) HandleResyncRequiredHandlerType {
    return .{ .effects = .{
        .context = client,
        .forget_workspace = forgetWorkspace,
        .request_snapshot = requestSnapshot,
        .request_handoff = requestHandoff,
    } };
}

fn forgetWorkspace(context: *anyopaque, workspace: WorkspaceLocationType) void {
    const client: *Client = @ptrCast(@alignCast(context));

    client.navigation_history.forget(workspace);
}

fn requestSnapshot(context: *anyopaque, workspace: WorkspaceLocationType) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try request_lifecycle.requestWorkspaceSnapshot(client, workspace);
}

fn requestHandoff(context: *anyopaque, workspace: WorkspaceIdType) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    _ = try workspace_handoffs.requestWorkspace(client, workspace);
}
