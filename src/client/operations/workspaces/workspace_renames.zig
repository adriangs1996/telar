//! Workspace rename requests correlated with canonical snapshots.

const Client = @import("../../AttachedClient.zig");
const request_lifecycle = @import("../../connection/request_lifecycle.zig");

const RequestRenameWorkspace = @import("../../application/workspaces/RequestRenameWorkspace.zig");
const std = @import("std");

/// Validates one request and retains its correlation before delivery. Example: `_ = try request(client, command);`
pub fn request(client: *Client, command: RequestRenameWorkspace) !bool {
    if (request_lifecycle.has(client, .workspace_operation)) {
        return false;
    }

    const current = client.model.workspaceLocation() orelse return false;
    if (!std.meta.eql(current, command.workspace)) {
        return false;
    }

    const request_id = try request_lifecycle.nextId(client);
    try request_lifecycle.deliverWorkspaceRename(client, .{
        .request_id = request_id,
        .workspace = command.workspace,
        .name = command.name,
    });

    return true;
}
