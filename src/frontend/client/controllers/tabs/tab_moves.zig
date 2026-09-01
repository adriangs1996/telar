//! Wires tab-move use cases to one client's protocol state.

const std = @import("std");
const core = @import("telar-core");
const tabs_application = @import("../../application/tabs/root.zig");
const client_model = @import("../../model/root.zig");

const Client = @import("../../client.zig");
const move_tab = tabs_application.move_tab;
const request_lifecycle = @import("../../request_lifecycle.zig");
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
    const continuation = request_lifecycle.consume(client, moved.request_id) orelse
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
    return request_lifecycle.has(client, .tab_operation);
}

fn sendMove(context: *anyopaque, intent: move_tab.TabMoveIntent) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const request_id = try request_lifecycle.nextId(client);
    try request_lifecycle.deliver(client, .{
        .registration = .{
            .request_id = request_id,
            .continuation = .{ .move_tab = intent.location },
        },
        .message = .{ .move_tab = .{
            .request_id = request_id,
            .location = intent.location,
            .direction = intent.direction,
        } },
    });
}
