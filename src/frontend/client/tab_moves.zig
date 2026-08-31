//! Wires tab-move use cases to one client's protocol state.

const std = @import("std");
const core = @import("telar-core");
const client_application = @import("application/root.zig");
const client_model = @import("model.zig");

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

/// Consumes one correlated response and commits its canonical tab position.
///
/// ```zig
/// const change = try apply(client, moved);
/// ```
pub fn apply(client: *Client, moved: schema.TabMoved) !client_model.Change {
    const continuation = client.requests.take(moved.request_id) orelse
        return error.UnexpectedTabMoved;
    const expected_location = switch (continuation) {
        .move_tab => |location| location,
        else => return error.UnexpectedTabMoved,
    };
    if (!std.meta.eql(expected_location, moved.location)) {
        return error.UnexpectedTabMoved;
    }

    var use_case = confirmationHandler(client);

    return use_case.execute(.{
        .location = moved.location,
        .position = moved.position,
    }) catch return error.UnexpectedTabMoved;
}

fn confirmationHandler(client: *Client) move_tab.ConfirmTabMoveHandler {
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
