//! Wires tab creation use cases to one client's protocol and attachments.

const std = @import("std");
const core = @import("telar-core");
const workspace_capability = @import("../workspace/root.zig");
const tabs_application = @import("application/tabs/root.zig");
const client_model = @import("model.zig");
const active_pane_resources = @import("active_pane_resources.zig");
const pane_focus_reports = @import("pane_focus_reports.zig");
const pane_pastes = @import("pane_pastes.zig");
const request_lifecycle = @import("request_lifecycle.zig");
const tab_attachments = @import("tab_attachments.zig");

const Client = @import("client.zig");
const create_tab = tabs_application.create_tab;
const multiplexer = workspace_capability.multiplexer;
const schema = core.schema;
const tab_creation_delivery = tabs_application.tab_creation_delivery;

/// Wires an interactive tab creation to planning and owned request delivery.
///
/// ```zig
/// var handler = requestHandler(client);
/// if (!try handler.execute(.{})) return;
/// ```
pub fn requestHandler(client: *Client) create_tab.RequestTabCreationHandler {
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
pub fn apply(client: *Client, created: schema.TabCreated) !client_model.TabCreation {
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

fn confirmationHandler(client: *Client) create_tab.ConfirmTabCreationHandler {
    return .{
        .model = &client.model,
        .delivery = .{
            .context = client,
            .deliver = deliverConfirmation,
        },
    };
}

fn deliverConfirmation(context: *anyopaque, creation: client_model.TabCreation) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    var use_case: tab_creation_delivery.DeliverTabCreationHandler = .{
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

fn sendCreation(context: *anyopaque, intent: create_tab.TabCreationIntent) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    const request_id = try request_lifecycle.nextId(client);
    try request_lifecycle.deliverCreateTab(client, .{
        .request_id = request_id,
        .workspace = intent.workspace,
        .label = intent.label,
        .size = multiplexer.rectSize(client.view.workbench()) orelse return error.TerminalTooSmall,
        .launch = .{
            .cwd = client.options.cwd,
            .cwd_source = intent.cwd_source,
            .arguments = client.options.arguments,
        },
    });
}

fn synchronizeActiveResources(context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try active_pane_resources.synchronize(client);
}
