//! Wires tab-rename use cases to one client's protocol state.

const Client = @import("../../AttachedClient.zig");
const RequestRenameTabHandlerType = @import("../../application/tabs/RequestRenameTabHandler.zig");
const TabRenamedType = @import("telar-core").TabRenamed;
const ChangeType = @import("../../model/types.zig").Change;
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const std = @import("std");
const ConfirmTabRenameHandlerType = @import("../../application/tabs/ConfirmTabRenameHandler.zig");
const TabRenameIntentType = @import("../../application/tabs/TabRenameIntent.zig");

/// Wires a rename request to the client's continuation tracker and outbox.
///
/// ```zig
/// var handler = requestHandler(client);
/// if (!try handler.execute(command)) {
///     return;
/// }
/// ```
pub fn requestHandler(client: *Client) RequestRenameTabHandlerType {
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

/// Consumes one correlated response and commits the canonical tab label.
///
/// ```zig
/// const change = try apply(client, renamed);
/// ```
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

    var use_case = confirmationHandler(client);

    return use_case.execute(.{
        .location = renamed.location,
        .label = renamed.label,
    }) catch return error.UnexpectedTabRenamed;
}

fn confirmationHandler(client: *Client) ConfirmTabRenameHandlerType {
    return .{ .model = &client.model };
}

fn tabOperationPending(context: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(context));
    return request_lifecycle.has(client, .tab_operation);
}

fn sendRename(context: *anyopaque, requested: TabRenameIntentType) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const request_id = try request_lifecycle.nextId(client);
    try request_lifecycle.deliverRename(client, .{
        .request_id = request_id,
        .location = requested.location,
        .label = requested.label,
    }, .{ .rename_tab = requested.location });
}
