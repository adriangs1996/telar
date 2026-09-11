//! Wires workspace creation use cases to one client's protocol and resources.

const Client = @import("../../Client.zig");
const RequestWorkspaceCreationHandlerType = @import("telar-client").RequestWorkspaceCreationHandler;
const OpenedPaneType = @import("telar-client").OpenedPane;
const TerminalSizeType = @import("telar-core").TerminalSize;
const ConfirmWorkspaceCreationType = @import("telar-client").ConfirmWorkspaceCreation;
const workspace_transitions = @import("workspace_transitions.zig");
const ConfirmWorkspaceCreationHandlerType = @import("telar-client").ConfirmWorkspaceCreationHandler;
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const WorkspaceCreationType = @import("telar-client").WorkspaceCreation;
const rectSize_module = @import("telar-client").rectSize;
const WorkspaceReplacementType = @import("telar-client").WorkspaceReplacement;
const DeliverWorkspaceCreationHandlerType = @import("telar-client").DeliverWorkspaceCreationHandler;

/// Wires a creation prompt to the client's continuation tracker and owned
/// outbox storage.
///
/// ```zig
/// var handler = requestHandler(client);
/// _ = try handler.execute(.{ .name = "agents" });
/// ```
pub fn requestHandler(client: *Client) RequestWorkspaceCreationHandlerType {
    return .{
        .model = &client.model,
        .gate = .{
            .context = client,
            .pending = requestPending,
        },
        .effects = .{
            .context = client,
            .send = sendCreation,
        },
    };
}

/// Builds the confirmed replacement with the runtime-selected root and an
/// exact remembered layout when one exists.
///
/// ```zig
/// const command = confirmation(client, opened, requested_size);
/// ```
pub fn confirmation(client: *Client, opened: OpenedPaneType, requested_size: TerminalSizeType) ConfirmWorkspaceCreationType {
    return .{
        .created = opened.created,
        .arrival = workspace_transitions.arrival(client, opened, requested_size),
    };
}

/// Wires a correlated response to atomic projection replacement followed by
/// resource release, focus synchronization and canonical snapshot requests.
///
/// ```zig
/// var handler = confirmationHandler(client);
/// _ = try handler.execute(command);
/// ```
pub fn confirmationHandler(client: *Client) ConfirmWorkspaceCreationHandlerType {
    return .{
        .model = &client.model,
        .delivery = .{
            .context = client,
            .deliver = deliverReplacement,
        },
    };
}

fn requestPending(context: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(context));
    return request_lifecycle.busy(client);
}

fn sendCreation(context: *anyopaque, creation: WorkspaceCreationType) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const request_id = try request_lifecycle.nextId(client);
    try request_lifecycle.deliverCreateWorkspace(client, .{
        .request_id = request_id,
        .size = rectSize_module(client.geometry().area) orelse return error.TerminalTooSmall,
        .name = creation.name,
        .launch = .{
            .cwd = client.options.cwd,
            .cwd_source = creation.cwd_source,
            .arguments = client.options.arguments,
        },
    });
}

fn deliverReplacement(context: *anyopaque, replacement: *const WorkspaceReplacementType) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    var use_case: DeliverWorkspaceCreationHandlerType = .{
        .model = &client.model,
        .release_effects = workspace_transitions.releaseEffects(client),
        .activation_effects = workspace_transitions.activationEffects(client),
    };

    try use_case.execute(replacement);
}
