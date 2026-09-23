//! Tab rename: sends a new tab label and adopts the runtime's answer.
const data = @import("model");
const core = @import("telar-core");
const std = @import("std");
const attached_client_tests = @import("../attached_client_tests.zig");
const agent_control = @import("../agents/agent_control.zig");
const tab_creation = @import("tab_creation.zig");
const Client = @import("../AttachedClient.zig");

/// Example: `_ = try tab_rename.requestTabRename(app, command);`
pub fn requestTabRename(client: *Client, command: data.RequestRenameTab) !bool {
    if (client.model.request_lifecycle.tracker.has(.tab_operation)) {
        return false;
    }

    try data.label_validation.validate(command.label, .renamed_tab);
    const location = client.model.tabLocation(command.tab_id) orelse return false;
    const request_id = try client.model.request_lifecycle.nextId();
    try sendTabRenameRequest(
        client,
        .{
            .request_id = request_id,
            .location = location,
            .label = command.label,
        },
        .{
            .rename_tab = location,
        },
    );

    return true;
}

/// Registers correlation before copying the request; failed delivery removes only that registration.
/// Example: `try tab_rename.sendTabRenameRequest(client, rename, continuation);`
fn sendTabRenameRequest(client: *Client, rename: core.RenameTab, continuation: data.RequestsContinuation) !void {
    try client.model.request_lifecycle.tracker.add(rename.request_id, continuation);
    errdefer _ = client.model.request_lifecycle.tracker.take(rename.request_id);
    try client.model.to_runtime.pushRename(rename);
}

pub fn completeTabRename(client: *Client, renamed: core.TabRenamed) !data.Change {
    const continuation = client.model.request_lifecycle.tracker.take(renamed.request_id) orelse
        return error.UnexpectedTabRenamed;
    const expected_location = switch (continuation) {
        .rename_tab => |location| location,
        else => return error.UnexpectedTabRenamed,
    };

    if (!std.meta.eql(expected_location, renamed.location)) {
        return error.UnexpectedTabRenamed;
    }

    return client.model.renameTab(
        .{
            .location = renamed.location,
            .label = renamed.label,
        },
    ) catch return error.UnexpectedTabRenamed;
}

test "owned request deliveries roll back only their own correlation when the outbox is full" {
    try attached_client_tests.rollBackFullOutbox(
        sendTabRenameRequest,
        tab_creation.sendCreateTabRequest,
        agent_control.sendAgentPromptRequest,
    );
}
