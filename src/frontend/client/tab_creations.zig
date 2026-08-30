//! Wires tab creation use cases to one client's protocol and attachments.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../workspace/root.zig");
const client_application = @import("application/root.zig");
const client_model = @import("model.zig");
const tab_attachments = @import("tab_attachments.zig");

const Client = @import("client.zig");
const create_tab = client_application.create_tab;
const multiplexer = workspace_capability.multiplexer;
const schema = core.schema;
const tabs_mod = workspace_capability.tabs;

/// Wires an interactive tab creation to planning and owned request delivery.
///
/// ```zig
/// var handler = requestHandler(client);
/// if (!try handler.execute(.{})) return;
/// ```
pub fn requestHandler(client: *Client) create_tab.RequestTabCreationHandler {
    return .{
        .model = &client.model,
        .gate = .{
            .context = client,
            .pending = tabOperationPending,
        },
        .effects = .{
            .context = client,
            .send = sendCreation,
        },
    };
}

/// Maps one canonical runtime response and its requested geometry into the
/// confirmation command consumed by the application handler.
///
/// ```zig
/// const command = confirmation(created, requested_size);
/// ```
pub fn confirmation(created: schema.TabCreated, requested_size: schema.TerminalSize) create_tab.ConfirmTabCreation {
    return .{
        .created = .{
            .location = created.location,
            .position = created.position,
            .label = created.label,
            .root_pane_id = created.root_pane_id,
        },
        .size = requested_size,
    };
}

/// Wires a correlated runtime confirmation to one model commit followed by
/// attachment synchronization.
///
/// ```zig
/// var handler = confirmationHandler(client);
/// _ = try handler.execute(command);
/// ```
pub fn confirmationHandler(client: *Client) create_tab.ConfirmTabCreationHandler {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .apply = applyConfirmation,
        },
    };
}

fn tabOperationPending(context: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(context));
    return client.requests.has(.tab_operation);
}

fn sendCreation(context: *anyopaque, intent: create_tab.TabCreationIntent) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const request_id = try client.nextId();
    try client.enqueueCreateTabRequest(.{
        .request_id = request_id,
        .workspace = intent.workspace,
        .label = intent.label,
        .size = multiplexer.rectSize(client.view.workbench()) orelse return error.TerminalTooSmall,
        .launch = .{
            .cwd = client.options.cwd,
            .cwd_source = intent.cwd_source,
            .arguments = client.options.arguments,
        },
    });
}

fn applyConfirmation(context: *anyopaque, creation: client_model.TabCreation) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const workspace = &client.model.workspace;
    const previous = findTab(workspace, creation.previous) orelse return error.UnexpectedTabCreation;
    const created = findTab(workspace, creation.created) orelse return error.UnexpectedTabCreation;

    try tab_attachments.detach(client, previous);
    try client.syncPaneFocus(&created.model);
}

fn findTab(workspace: *tabs_mod.Model, location: schema.TabLocation) ?*tabs_mod.Tab {
    const tab = workspace.find(location.tab_id) orelse return null;
    if (!std.meta.eql(tab.location, location)) {
        return null;
    }

    return tab;
}
