//! Requests tab renames and applies correlated runtime labels.

const Client = @import("../../AttachedClient.zig");
const TabRenamedType = @import("telar-core").TabRenamed;
const ChangeType = @import("../../model/types.zig").Change;
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const std = @import("std");

const RequestRenameTab = @import("../../application/tabs/RequestRenameTab.zig");
const rename_tab = @import("../../application/tabs/rename_tab.zig");

/// Validates one request and retains its correlation before delivery. Example: `_ = try request(client, command);`
pub fn request(client: *Client, command: RequestRenameTab) !bool {
    if (request_lifecycle.has(client, .tab_operation)) {
        return false;
    }

    try rename_tab.validateLabel(command.label);
    const location = client.model.tabLocation(command.tab_id) orelse return false;
    const request_id = try request_lifecycle.nextId(client);
    try request_lifecycle.deliverRename(client, .{
        .request_id = request_id,
        .location = location,
        .label = command.label,
    }, .{ .rename_tab = location });

    return true;
}

/// Consumes one correlated runtime completion before committing canonical state. Example: `_ = try apply(client, response);`
pub fn apply(client: *Client, renamed: TabRenamedType) !ChangeType {
    const continuation = request_lifecycle.consume(client, renamed.request_id) orelse
        return error.UnexpectedTabRenamed;
    const expected_location = switch (continuation) {
        .rename_tab => |location| location,
        else => return error.UnexpectedTabRenamed,
    };
    if (!std.meta.eql(expected_location, renamed.location)) {
        return error.UnexpectedTabRenamed;
    }

    return client.model.renameTab(.{
        .location = renamed.location,
        .label = renamed.label,
    }) catch return error.UnexpectedTabRenamed;
}
