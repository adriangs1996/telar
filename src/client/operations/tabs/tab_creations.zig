//! Requests and confirms tab creation for one client.

const Client = @import("../../AttachedClient.zig");
const TabCreatedType = @import("telar-core").TabCreated;
const TabCreationType = @import("../../model/TabCreation.zig");
const std = @import("std");
const tab_attachments = @import("tab_attachments.zig");
const rectSize_module = @import("../../workspace/multiplexer.zig").rectSize;

const RequestTabCreation = @import("../../application/tabs/RequestTabCreation.zig");
const create_tab = @import("../../application/tabs/create_tab.zig");
const agent_threads = @import("../agents/agent_threads.zig");

/// Validates one request and retains its correlation before delivery. Example: `_ = try request(client, command);`
pub fn request(client: *Client, command: RequestTabCreation) !bool {
    if (client.request_lifecycle.tracker.has(.tab_operation)) {
        return false;
    }

    try create_tab.validateLabel(command.label);
    const plan = client.model.planTabCreation() orelse return false;
    const request_id = try client.request_lifecycle.nextId();
    try client.sendCreateTabRequest(.{
        .kind = command.kind,
        .request_id = request_id,
        .workspace = plan.workspace,
        .label = command.label,
        .size = rectSize_module(client.geometry().area) orelse return error.TerminalTooSmall,
        .launch = .{
            .cwd = client.options.cwd,
            .cwd_source = plan.cwd_source,
            .arguments = if (command.kind == .agent) &.{} else if (command.arguments.len != 0) command.arguments else client.options.arguments,
        },
    });

    return true;
}

/// Consumes one correlated runtime completion before committing canonical state. Example: `_ = try apply(client, response);`
pub fn apply(client: *Client, created: TabCreatedType) !TabCreationType {
    const continuation = client.request_lifecycle.tracker.take(created.request_id) orelse
        return error.UnexpectedTabCreated;
    const requested = switch (continuation) {
        .create_tab => |creation| creation,
        else => return error.UnexpectedTabCreated,
    };
    if (!std.meta.eql(requested.workspace, created.location.workspace)) {
        return error.UnexpectedTabCreated;
    }

    const creation = try client.model.createTab(.{
        .created = .{
            .location = created.location,
            .position = created.position,
            .label = created.label,
            .root_pane_id = created.root_pane_id,
            .kind = created.kind,
            .pane_generation = created.pane_generation,
        },
        .size = requested.size,
    });
    try tab_attachments.detach(client, creation.previous);
    try client.synchronizeActivePane();

    if (created.kind == .agent) {
        try agent_threads.query(client, created.root_pane_id);
    }

    return creation;
}
