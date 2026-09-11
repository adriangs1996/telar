//! Client adapters for workspace-rename requests.

const Client = @import("../../Client.zig");
const RequestRenameWorkspaceHandlerType = @import("telar-client").RequestRenameWorkspaceHandler;
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const RequestedRenameType = @import("telar-client").RequestedRename;

/// Wires a workspace rename to the client's continuation tracker and outbox.
///
/// ```zig
/// var handler = requestHandler(client);
/// _ = try handler.execute(command);
/// ```
pub fn requestHandler(client: *Client) RequestRenameWorkspaceHandlerType {
    return .{
        .model = &client.model,
        .gate = .{
            .context = client,
            .pending = workspaceOperationPending,
        },
        .effects = .{
            .context = client,
            .send = sendRename,
        },
    };
}

fn workspaceOperationPending(context: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(context));
    return request_lifecycle.has(client, .workspace_operation);
}

fn sendRename(context: *anyopaque, requested: RequestedRenameType) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const request_id = try request_lifecycle.nextId(client);
    try request_lifecycle.deliverWorkspaceRename(client, .{
        .request_id = request_id,
        .workspace = requested.workspace,
        .name = requested.name,
    });
}
