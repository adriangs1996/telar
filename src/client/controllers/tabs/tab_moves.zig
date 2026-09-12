//! Wires tab-move use cases to one client's protocol state.

const Client = @import("../../AttachedClient.zig");
const RequestTabMoveHandlerType = @import("../../application/tabs/RequestTabMoveHandler.zig");
const TabMovedType = @import("telar-core").TabMoved;
const ChangeType = @import("../../model/types.zig").Change;
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const std = @import("std");
const ConfirmTabMoveHandlerType = @import("../../application/tabs/ConfirmTabMoveHandler.zig");
const TabMoveIntentType = @import("../../application/tabs/TabMoveIntent.zig");

/// Wires an interactive move to the tab-operation gate and runtime request.
///
/// ```zig
/// var handler = requestHandler(client);
/// if (!try handler.execute(.{ .direction = .next })) {
///     return;
/// }
/// ```
pub fn requestHandler(client: *Client) RequestTabMoveHandlerType {
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
pub fn apply(client: *Client, moved: TabMovedType) !ChangeType {
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

fn confirmationHandler(client: *Client) ConfirmTabMoveHandlerType {
    return .{ .model = &client.model };
}

fn tabOperationPending(context: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(context));
    return request_lifecycle.has(client, .tab_operation);
}

fn sendMove(context: *anyopaque, intent: TabMoveIntentType) !void {
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
