//! Client adapters for tab-rename requests.

const client_application = @import("application/root.zig");

const Client = @import("client.zig");
const rename_tab = client_application.rename_tab;

/// Wires a rename request to the client's continuation tracker and outbox.
///
/// ```zig
/// var handler = requestHandler(client);
/// _ = try handler.execute(command);
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

fn tabOperationPending(context: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(context));
    return client.requests.has(.tab_operation);
}

fn sendRename(context: *anyopaque, requested: rename_tab.RequestedRename) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const request_id = try client.nextId();
    try client.enqueueRenameRequest(.{
        .request_id = request_id,
        .location = requested.location,
        .label = requested.label,
    }, .{ .rename_tab = requested.location });
}
