//! Requests and commits workspace replacement with its resource lifecycle.

const Client = @import("../../AttachedClient.zig");
const OpenedPaneType = @import("../../application/panes/OpenedPane.zig");
const TerminalSizeType = @import("telar-core").TerminalSize;
const ConfirmWorkspaceCreationType = @import("../../application/workspaces/ConfirmWorkspaceCreation.zig");
const workspace_transitions = @import("workspace_transitions.zig");
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const rectSize_module = @import("../../workspace/multiplexer.zig").rectSize;
const WorkspaceReplacementType = @import("../../model/WorkspaceReplacement.zig");

const RequestWorkspaceCreation = @import("../../application/workspaces/RequestWorkspaceCreation.zig");
const create_workspace = @import("../../application/workspaces/create_workspace.zig");

const PaneIdType = @import("telar-core").PaneId;

/// Validates one request and retains its correlation before delivery. Example: `_ = try request(client, command);`
pub fn request(client: *Client, command: RequestWorkspaceCreation) !bool {
    if (request_lifecycle.busy(client)) {
        return false;
    }

    try create_workspace.validateName(command.name);
    const cwd_source: ?PaneIdType = if (command.cwd.len == 0)
        client.model.planWorkspaceCreation() orelse return false
    else
        null;
    const request_id = try request_lifecycle.nextId(client);
    try request_lifecycle.deliverCreateWorkspace(client, .{
        .request_id = request_id,
        .size = rectSize_module(client.geometry().area) orelse return error.TerminalTooSmall,
        .name = command.name,
        .create_cwd = command.create_cwd,
        .launch = .{
            .cwd = if (command.cwd.len != 0) command.cwd else client.options.cwd,
            .cwd_source = cwd_source,
            .arguments = client.options.arguments,
        },
    });

    return true;
}

/// Constructs the confirmed replacement and remembers an exact saved layout. Example: `const command = confirmation(client, opened, size);`
pub fn confirmation(client: *Client, opened: OpenedPaneType, requested_size: TerminalSizeType) ConfirmWorkspaceCreationType {
    return .{
        .created = opened.created,
        .arrival = workspace_transitions.arrival(client, opened, requested_size),
    };
}

/// Replaces the projection atomically, then retires its resources and activates the new root. Example: `_ = try confirm(client, command);`
pub fn confirm(client: *Client, command: ConfirmWorkspaceCreationType) !WorkspaceReplacementType {
    if (!command.created) {
        return error.UnexpectedRequest;
    }

    const replacement = try client.model.replaceWorkspace(command.arrival);
    workspace_transitions.release(client, &replacement.departure);
    try workspace_transitions.activate(client, replacement.activation);

    return replacement;
}
