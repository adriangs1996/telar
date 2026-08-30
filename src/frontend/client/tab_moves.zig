//! Wires tab-move use cases to one client's protocol state.

const core = @import("telar-core");
const client_application = @import("application/root.zig");

const Client = @import("client.zig");
const move_tab = client_application.move_tab;
const schema = core.schema;

/// Wires an interactive move to the tab-operation gate and runtime request.
///
/// ```zig
/// var handler = requestHandler(client);
/// if (!try handler.execute(.{ .direction = .next })) {
///     return;
/// }
/// ```
pub fn requestHandler(client: *Client) move_tab.RequestTabMoveHandler {
    return .{
        .model = &client.model,
        .gate = .{
            .context = client,
            .pending = tabOperationPending,
        },
        .effects = .{
            .context = client,
            .send = sendMove,
        },
    };
}

/// Removes protocol-only correlation data from one canonical response.
///
/// ```zig
/// const command = confirmation(moved);
/// ```
pub fn confirmation(moved: schema.TabMoved) move_tab.ConfirmTabMove {
    return .{
        .location = moved.location,
        .position = moved.position,
    };
}

/// Wires a correlated runtime response to the passive client model.
///
/// ```zig
/// var handler = confirmationHandler(client);
/// _ = try handler.execute(command);
/// ```
pub fn confirmationHandler(client: *Client) move_tab.ConfirmTabMoveHandler {
    return .{ .model = &client.model };
}

fn tabOperationPending(context: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(context));
    return client.requests.has(.tab_operation);
}

fn sendMove(context: *anyopaque, intent: move_tab.TabMoveIntent) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const request_id = try client.nextId();
    try client.enqueueRequest(
        request_id,
        .{ .move_tab = intent.location },
        .{ .move_tab = .{
            .request_id = request_id,
            .location = intent.location,
            .direction = intent.direction,
        } },
    );
}
