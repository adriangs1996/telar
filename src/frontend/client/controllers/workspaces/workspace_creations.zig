//! Wires workspace creation use cases to one client's protocol and resources.

const core = @import("telar-core");
const workspace_capability = @import("../../../workspace/root.zig");
const panes_application = @import("../../application/panes/root.zig");
const workspaces_application = @import("../../application/workspaces/root.zig");
const client_model = @import("../../model/root.zig");
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const workspace_transitions = @import("workspace_transitions.zig");

const Client = @import("../../client.zig");
const create_workspace = workspaces_application.create_workspace;
const multiplexer = workspace_capability.multiplexer;
const pane_open_delivery = panes_application.pane_open_delivery;
const schema = core.schema;
const workspace_creation_delivery = workspaces_application.workspace_creation_delivery;

/// Wires a creation prompt to the client's continuation tracker and owned
/// outbox storage.
///
/// ```zig
/// var handler = requestHandler(client);
/// _ = try handler.execute(.{ .name = "agents" });
/// ```
pub fn requestHandler(client: *Client) create_workspace.RequestWorkspaceCreationHandler {
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
pub fn confirmation(client: *Client, opened: pane_open_delivery.OpenedPane, requested_size: schema.TerminalSize) create_workspace.ConfirmWorkspaceCreation {
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
pub fn confirmationHandler(client: *Client) create_workspace.ConfirmWorkspaceCreationHandler {
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

fn sendCreation(context: *anyopaque, creation: create_workspace.WorkspaceCreation) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const request_id = try request_lifecycle.nextId(client);
    try request_lifecycle.deliverCreateWorkspace(client, .{
        .request_id = request_id,
        .size = multiplexer.rectSize(client.view.workbench()) orelse return error.TerminalTooSmall,
        .name = creation.name,
        .launch = .{
            .cwd = client.options.cwd,
            .cwd_source = creation.cwd_source,
            .arguments = client.options.arguments,
        },
    });
}

fn deliverReplacement(context: *anyopaque, replacement: *const client_model.WorkspaceReplacement) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    var use_case: workspace_creation_delivery.DeliverWorkspaceCreationHandler = .{
        .model = &client.model,
        .release_effects = workspace_transitions.releaseEffects(client),
        .activation_effects = workspace_transitions.activationEffects(client),
    };

    try use_case.execute(replacement);
}
