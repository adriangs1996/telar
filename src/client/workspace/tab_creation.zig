//! Tab creation: asks the runtime for a new tab and adopts it when it arrives.
const data = @import("model");
const core = @import("telar-core");
const std = @import("std");
const agent_control = @import("../agents/agent_control.zig");
const pane_focus = @import("../panes/pane_focus.zig");
const tab_removal = @import("tab_removal.zig");
const Client = @import("../execution/Client.zig");

/// Example: `_ = try tab_creation.requestTabCreation(app, command);`
pub fn requestTabCreation(client: *Client, command: data.RequestTabCreation) !bool {
    if (client.model.request_lifecycle.tracker.has(.tab_operation)) {
        return false;
    }

    try data.label_validation.validate(command.label, .new_tab);
    const plan = data.tab_creation.planCreation(&client.model) orelse return false;
    const request_id = try client.model.request_lifecycle.nextId();
    try sendCreateTabRequest(
        &client.model,
        .{
            .kind = command.kind,
            .request_id = request_id,
            .workspace = plan.workspace,
            .label = command.label,
            .size = data.multiplexer.rectSize(client.geometry().area) orelse return error.TerminalTooSmall,
            .launch = .{
                .cwd = client.options.cwd,
                .cwd_source = plan.cwd_source,
                .arguments = if (command.kind == .agent) &.{} else if (command.arguments.len != 0) command.arguments else client.options.arguments,
            },
        },
    );

    return true;
}

/// Registers correlation before copying the request; failed delivery removes only that registration.
/// Example: `try tab_creation.sendCreateTabRequest(client, request);`
pub fn sendCreateTabRequest(model: *data.ClientModel, request: core.CreateTab) !void {
    try model.request_lifecycle.tracker.add(
        request.request_id,
        .{
            .create_tab = .{
                .workspace = request.workspace,
                .size = request.size,
            },
        },
    );
    errdefer _ = model.request_lifecycle.tracker.take(request.request_id);
    try model.to_runtime.pushCreateTab(request);
}

pub fn completeTabCreation(client: *Client, created: core.TabCreated) !data.TabCreation {
    const continuation = client.model.request_lifecycle.tracker.take(created.request_id) orelse
        return error.UnexpectedTabCreated;
    const requested = switch (continuation) {
        .create_tab => |creation| creation,
        else => return error.UnexpectedTabCreated,
    };

    if (!std.meta.eql(requested.workspace, created.location.workspace)) {
        return error.UnexpectedTabCreated;
    }

    const creation = try data.tab_creation.create(&client.model, 
        .{
            .created = .{
                .location = created.location,
                .position = created.position,
                .label = created.label,
                .root_pane_id = created.root_pane_id,
                .kind = created.kind,
                .pane_generation = created.pane_generation,
            },
            .size = requested.size,
        },
    );
    try tab_removal.detachTab(client, creation.previous);
    try pane_focus.synchronizeActivePane(client);

    if (created.kind == .agent) {
        try agent_control.queryAgentThread(&client.model, created.root_pane_id);
    }

    return creation;
}
