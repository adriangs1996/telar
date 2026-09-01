//! Wires tab-rename use cases to one client's protocol state.

const std = @import("std");
const core = @import("telar-core");
const tabs_application = @import("application/tabs/root.zig");
const client_model = @import("model.zig");

const Client = @import("client.zig");
const rename_tab = tabs_application.rename_tab;
const request_lifecycle = @import("request_lifecycle.zig");
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

/// Consumes one correlated response and commits the canonical tab label.
///
/// ```zig
/// const change = try apply(client, renamed);
/// ```
pub fn apply(client: *Client, renamed: schema.TabRenamed) !client_model.Change {
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

fn confirmationHandler(client: *Client) rename_tab.ConfirmTabRenameHandler {
    return .{ .model = &client.model };
}

fn tabOperationPending(context: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(context));
    return request_lifecycle.has(client, .tab_operation);
}

fn sendRename(context: *anyopaque, requested: rename_tab.TabRenameIntent) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const request_id = try request_lifecycle.nextId(client);
    try request_lifecycle.deliverRename(client, .{
        .request_id = request_id,
        .location = requested.location,
        .label = requested.label,
    }, .{ .rename_tab = requested.location });
}
