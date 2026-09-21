//! Requests tab movement and applies correlated runtime positions.

const Client = @import("../../AttachedClient.zig");
const TabMovedType = @import("telar-core").TabMoved;
const ChangeType = @import("../../model/types.zig").Change;
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const std = @import("std");

const RequestTabMove = @import("../../application/tabs/RequestTabMove.zig");

/// Validates one request and retains its correlation before delivery. Example: `_ = try request(client, command);`
pub fn request(client: *Client, command: RequestTabMove) !bool {
    if (request_lifecycle.has(client, .tab_operation)) {
        return false;
    }

    const location = command.location orelse client.model.activeTabLocation() orelse return false;
    const workspace = client.model.workspace.workspace orelse return false;
    if (!std.meta.eql(workspace, location.workspace) or client.model.workspace.indexOf(location.tab_id) == null) {
        return false;
    }

    if (command.relative_to) |anchor| {
        if (anchor == location.tab_id or client.model.workspace.indexOf(anchor) == null) {
            return false;
        }
    }

    const request_id = try request_lifecycle.nextId(client);
    try request_lifecycle.deliver(client, .{
        .registration = .{
            .request_id = request_id,
            .continuation = .{ .move_tab = location },
        },
        .message = .{ .move_tab = .{
            .request_id = request_id,
            .location = location,
            .direction = command.direction,
            .relative_to = command.relative_to,
        } },
    });

    return true;
}

/// Consumes one correlated runtime completion before committing canonical state. Example: `_ = try apply(client, response);`
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

    return client.model.applyTabPosition(moved.location, moved.position) catch return error.UnexpectedTabMoved;
}
