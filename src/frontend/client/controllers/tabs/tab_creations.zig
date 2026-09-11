//! Wires tab creation use cases to one client's protocol and attachments.

const Client = @import("../../Client.zig");
const RequestTabCreationHandlerType = @import("telar-client").RequestTabCreationHandler;
const TabCreatedType = @import("telar-core").TabCreated;
const TabCreationType = @import("telar-client").TabCreation;
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const std = @import("std");
const ConfirmTabCreationHandlerType = @import("telar-client").ConfirmTabCreationHandler;
const DeliverTabCreationHandlerType = @import("telar-client").DeliverTabCreationHandler;
const pane_pastes = @import("../input/pane_pastes.zig");
const pane_focus_reports = @import("../panes/pane_focus_reports.zig");
const tab_attachments = @import("tab_attachments.zig");
const TabCreationIntentType = @import("telar-client").TabCreationIntent;
const rectSize_module = @import("telar-client").rectSize;
const active_pane_resources = @import("../panes/active_pane_resources.zig");

/// Wires an interactive tab creation to planning and owned request delivery.
///
/// ```zig
/// var handler = requestHandler(client);
/// if (!try handler.execute(.{})) return;
/// ```
pub fn requestHandler(client: *Client) RequestTabCreationHandlerType {
    return .{
        .model = &client.model,
        .gate = .{
            .context = client,
            .pending = tabOperationPending,
        },
        .effects = .{
            .context = client,
            .send = sendCreation,
        },
    };
}

/// Consumes one correlated response and commits the canonical tab creation.
///
/// ```zig
/// const creation = try apply(client, created);
/// ```
pub fn apply(client: *Client, created: TabCreatedType) !TabCreationType {
    const continuation = request_lifecycle.consume(client, created.request_id) orelse
        return error.UnexpectedTabCreated;
    const requested = switch (continuation) {
        .create_tab => |creation| creation,
        else => return error.UnexpectedTabCreated,
    };
    if (!std.meta.eql(requested.workspace, created.location.workspace)) {
        return error.UnexpectedTabCreated;
    }

    var use_case = confirmationHandler(client);

    return use_case.execute(.{
        .created = .{
            .location = created.location,
            .position = created.position,
            .label = created.label,
            .root_pane_id = created.root_pane_id,
        },
        .size = requested.size,
    });
}

fn confirmationHandler(client: *Client) ConfirmTabCreationHandlerType {
    return .{
        .model = &client.model,
        .delivery = .{
            .context = client,
            .deliver = deliverConfirmation,
        },
    };
}

fn deliverConfirmation(context: *anyopaque, creation: TabCreationType) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    var use_case: DeliverTabCreationHandlerType = .{
        .model = &client.model,
        .paste_effects = pane_pastes.effects(client),
        .focus_effects = pane_focus_reports.effects(client),
        .attachment_effects = tab_attachments.effects(client),
        .effects = .{
            .context = client,
            .synchronize_active_resources = synchronizeActiveResources,
        },
    };

    try use_case.execute(creation);
}

fn tabOperationPending(context: *anyopaque) bool {
    const client: *Client = @ptrCast(@alignCast(context));
    return request_lifecycle.has(client, .tab_operation);
}

fn sendCreation(context: *anyopaque, intent: TabCreationIntentType) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const request_id = try request_lifecycle.nextId(client);
    try request_lifecycle.deliverCreateTab(client, .{
        .request_id = request_id,
        .workspace = intent.workspace,
        .label = intent.label,
        .size = rectSize_module(client.geometry().area) orelse return error.TerminalTooSmall,
        .launch = .{
            .cwd = client.options.cwd,
            .cwd_source = intent.cwd_source,
            .arguments = if (intent.arguments.len != 0) intent.arguments else client.options.arguments,
        },
    });
}

fn synchronizeActiveResources(context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try active_pane_resources.synchronize(client);
}
