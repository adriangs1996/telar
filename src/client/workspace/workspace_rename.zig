//! Workspace rename: sends a new workspace name to the runtime.
const data = @import("model");
const core = @import("telar-core");
const std = @import("std");
const Client = @import("../execution/Client.zig");

/// Registers correlation before copying the request; failed delivery removes only that registration.
/// Example: `try workspace_rename.sendWorkspaceRenameRequest(client, rename);`
pub fn sendWorkspaceRenameRequest(model: *data.ClientModel, rename: core.RenameWorkspace) !void {
    try model.request_lifecycle.tracker.add(
        rename.request_id,
        .{
            .rename_workspace = rename.workspace,
        },
    );
    errdefer _ = model.request_lifecycle.tracker.take(rename.request_id);
    try model.to_runtime.pushWorkspaceRename(rename);
}

/// Validates one request and retains its correlation before delivery. Example: `_ = try request(client, command);`
pub fn requestWorkspaceRename(model: *data.ClientModel, command: data.RequestRenameWorkspace) !bool {
    if (model.request_lifecycle.tracker.has(.workspace_operation)) {
        return false;
    }

    const current = model.workspace orelse return false;
    if (!std.meta.eql(current, command.workspace)) {
        return false;
    }

    const request_id = try model.request_lifecycle.nextId();
    try sendWorkspaceRenameRequest(
        model,
        .{
            .request_id = request_id,
            .workspace = command.workspace,
            .name = command.name,
        },
    );

    return true;
}
