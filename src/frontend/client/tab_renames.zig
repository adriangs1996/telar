//! Wires tab-rename use cases to one client's protocol state.

const core = @import("telar-core");
const client_application = @import("application/root.zig");

const Client = @import("client.zig");
const rename_tab = client_application.rename_tab;
const schema = core.schema;

/// Wires a rename request to the client's continuation tracker and outbox.
///
/// ```zig
/// var handler = requestHandler(client);
/// if (!try handler.execute(command)) {
///     return;
/// }
/// ```
pub fn requestHandler(client: *Client) rename_tab.RequestRenameTabHandler {
    return .{
        .model = &client.model,
        .gate = .{
            .context = client,
            .pending = tabOperationPending,
        },
        .effects = .{
            .context = client,
            .send = sendRename,
        },
    };
}

/// Removes protocol-only correlation data from one canonical response.
///
/// ```zig
/// const command = confirmation(renamed);
/// ```
pub fn confirmation(renamed: schema.TabRenamed) rename_tab.ConfirmTabRename {
    return .{
        .location = renamed.location,
        .label = renamed.label,
    };
}

/// Wires a correlated runtime response to the passive client model.
///
/// ```zig
/// var handler = confirmationHandler(client);
/// _ = try handler.execute(command);
/// ```
pub fn confirmationHandler(client: *Client) rename_tab.ConfirmTabRenameHandler {
    return .{ .model = &client.model };
}

fn tabOperationPending(context: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(context));
    return client.requests.has(.tab_operation);
}

fn sendRename(context: *anyopaque, requested: rename_tab.TabRenameIntent) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const request_id = try client.nextId();
    try client.enqueueRenameRequest(.{
        .request_id = request_id,
        .location = requested.location,
        .label = requested.label,
    }, .{ .rename_tab = requested.location });
}
