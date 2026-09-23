//! Workspace rename: sends a new workspace name to the runtime.
const data = @import("model");
const core = @import("telar-core");
const std = @import("std");
const Client = @import("../AttachedClient.zig");

/// Registers correlation before copying the request; failed delivery removes only that registration.
/// Example: `try workspace_rename.sendWorkspaceRenameRequest(client, rename);`
pub fn sendWorkspaceRenameRequest(client: *Client, rename: core.RenameWorkspace) !void {
    try client.model.request_lifecycle.tracker.add(
        rename.request_id,
        .{
            .rename_workspace = rename.workspace,
        },
    );
    errdefer _ = client.model.request_lifecycle.tracker.take(rename.request_id);
    try client.model.to_runtime.pushWorkspaceRename(rename);
}

/// Validates one request and retains its correlation before delivery. Example: `_ = try request(client, command);`
pub fn requestWorkspaceRename(client: *Client, command: data.RequestRenameWorkspace) !bool {
    if (client.model.request_lifecycle.tracker.has(.workspace_operation)) {
        return false;
    }

    const current = client.model.workspace orelse return false;
    if (!std.meta.eql(current, command.workspace)) {
        return false;
    }

    const request_id = try client.model.request_lifecycle.nextId();
    try sendWorkspaceRenameRequest(
        client,
        .{
            .request_id = request_id,
            .workspace = command.workspace,
            .name = command.name,
        },
    );

    return true;
}
