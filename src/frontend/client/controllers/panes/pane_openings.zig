//! Correlates successful pane-open responses with the client operation that
//! requested them and delivers one translated confirmation.

const core = @import("telar-core");
const panes_application = @import("../../application/panes/root.zig");

const Client = @import("../../client.zig");
const pane_attachments = @import("pane_attachments.zig");
const pane_splits = @import("pane_splits.zig");
const request_lifecycle = @import("../../request_lifecycle.zig");
const workspace_creations = @import("../workspaces/workspace_creations.zig");
const workspace_handoffs = @import("../workspaces/workspace_handoffs.zig");
const pane_open_delivery = panes_application.pane_open_delivery;
const schema = core.schema;

pub const Outcome = pane_open_delivery.Outcome;

/// Consumes one correlated open continuation and delivers its confirmation.
///
/// ```zig
/// _ = try apply(client, opened);
/// ```
pub fn apply(client: *Client, opened: schema.PaneOpened) !Outcome {
    const continuation = request_lifecycle.consume(client, opened.request_id) orelse
        return error.UnexpectedRequest;
    const delivery: pane_open_delivery.Continuation = switch (continuation) {
        .initial_open => pane_open_delivery.Continuation.initial_open,
        .create_workspace => |requested_size| .{ .create_workspace = requested_size },
        .split => |split| .{ .split = .{
            .target_pane = split.target_pane,
            .location = split.location,
            .axis = split.axis,
            .area = split.area,
        } },
        .attach_pane => |attachment| .{ .attach_pane = .{
            .pane_id = attachment.pane_id,
            .location = attachment.location,
        } },
        .ignored => pane_open_delivery.Continuation.ignored,
        else => return error.UnexpectedRequest,
    };
    var use_case: pane_open_delivery.DeliverPaneOpenHandler = .{
        .effects = .{
            .context = client,
            .arrive_workspace = arriveWorkspace,
            .create_workspace = createWorkspace,
            .confirm_split = confirmSplit,
            .confirm_attachment = confirmAttachment,
        },
    };

    return use_case.execute(.{
        .continuation = delivery,
        .opened = translate(opened),
    });
}

fn translate(opened: schema.PaneOpened) pane_open_delivery.OpenedPane {
    return .{
        .pane_id = opened.pane_id,
        .location = opened.location,
        .created = opened.created,
    };
}

fn arriveWorkspace(raw_context: *anyopaque, opened: pane_open_delivery.OpenedPane) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));
    var use_case = workspace_handoffs.confirmationHandler(client);

    try use_case.execute(try workspace_handoffs.arrival(client, opened));
}

fn createWorkspace(raw_context: *anyopaque, confirmation: pane_open_delivery.WorkspaceCreation) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));
    var use_case = workspace_creations.confirmationHandler(client);

    _ = try use_case.execute(workspace_creations.confirmation(
        client,
        confirmation.opened,
        confirmation.requested_size,
    ));
}

fn confirmSplit(raw_context: *anyopaque, confirmation: pane_open_delivery.PaneSplitConfirmation) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));
    var use_case = pane_splits.confirmationHandler(client);

    _ = try use_case.execute(.{
        .requested = confirmation.requested,
        .confirmed_pane = confirmation.opened.pane_id,
        .confirmed_location = confirmation.opened.location,
        .created = confirmation.opened.created,
    });
}

fn confirmAttachment(raw_context: *anyopaque, confirmation: pane_open_delivery.PaneAttachmentConfirmation) !void {
    const client: *Client = @ptrCast(@alignCast(raw_context));
    var use_case = pane_attachments.confirmationHandler(client);

    _ = try use_case.execute(.{
        .requested = confirmation.requested,
        .confirmed = .{
            .pane_id = confirmation.opened.pane_id,
            .location = confirmation.opened.location,
        },
        .created = confirmation.opened.created,
    });
}
