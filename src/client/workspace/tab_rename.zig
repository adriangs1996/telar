//! Tab rename: sends a new tab label and adopts the runtime's answer.
const data = @import("model");
const core = @import("telar-core");
const std = @import("std");
const client_tests = @import("../execution/client_tests.zig");
const agent_control = @import("../agents/agent_control.zig");
const tab_creation = @import("tab_creation.zig");

/// Example: `_ = try tab_rename.requestTabRename(app, command);`
pub fn requestTabRename(model: *data.ClientModel, command: data.RequestRenameTab) !bool {
    if (model.request_lifecycle.tracker.has(.tab_operation)) {
        return false;
    }

    try data.label_validation.validate(command.label, .renamed_tab);
    const location = model.tabLocation(command.tab_id) orelse return false;
    const request_id = try model.request_lifecycle.nextId();
    try sendTabRenameRequest(
        model,
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
fn sendTabRenameRequest(model: *data.ClientModel, rename: core.RenameTab, continuation: data.RequestsContinuation) !void {
    try model.request_lifecycle.tracker.add(rename.request_id, continuation);
    errdefer _ = model.request_lifecycle.tracker.take(rename.request_id);
    try model.to_runtime.pushRename(rename);
}

pub fn completeTabRename(model: *data.ClientModel, renamed: core.TabRenamed) !data.Change {
    const continuation = model.request_lifecycle.tracker.take(renamed.request_id) orelse
        return error.UnexpectedTabRenamed;
    const expected_location = switch (continuation) {
        .rename_tab => |location| location,
        else => return error.UnexpectedTabRenamed,
    };

    if (!std.meta.eql(expected_location, renamed.location)) {
        return error.UnexpectedTabRenamed;
    }

    return model.renameTab(
        .{
            .location = renamed.location,
            .label = renamed.label,
        },
    ) catch return error.UnexpectedTabRenamed;
}

test "owned request deliveries roll back only their own correlation when the outbox is full" {
    try client_tests.rollBackFullOutbox(
        sendTabRenameRequest,
        tab_creation.sendCreateTabRequest,
        agent_control.sendAgentPromptRequest,
    );
}
