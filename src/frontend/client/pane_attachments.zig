//! Wires per-pane attachment confirmation and canonical recovery to a client.

const core = @import("telar-core");
const client_application = @import("application/root.zig");

const Client = @import("client.zig");
const attach_pane = client_application.attach_pane;
const schema = core.schema;

/// Wires a runtime attachment confirmation to the passive client model.
///
/// ```zig
/// var handler = confirmationHandler(client);
/// _ = try handler.execute(command);
/// ```
pub fn confirmationHandler(client: *Client) attach_pane.ConfirmPaneAttachmentHandler {
    return .{ .model = &client.model };
}

/// Wires a stale membership failure to one coalesced canonical tab snapshot.
///
/// ```zig
/// var handler = recoveryHandler(client);
/// _ = try handler.execute(attachment);
/// ```
pub fn recoveryHandler(client: *Client) attach_pane.RecoverPaneAttachmentHandler {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .refresh = refreshTab,
        },
    };
}

fn refreshTab(context: *anyopaque, location: schema.TabLocation) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    if (client.requests.has(.tab_snapshot)) {
        return;
    }

    try client.requestTabSnapshot(location);
}
