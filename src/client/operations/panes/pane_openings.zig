//! Correlates successful pane-open responses with the client operation that
//! requested them and delivers one translated confirmation.

const Client = @import("../../AttachedClient.zig");
const PaneOpenedType = @import("telar-core").PaneOpened;
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const OpenedPaneType = @import("../../application/panes/OpenedPane.zig");
const workspace_handoffs = @import("../workspaces/workspace_handoffs.zig");
const WorkspaceCreationType = @import("../../application/panes/WorkspaceCreation.zig");
const workspace_creations = @import("../workspaces/workspace_creations.zig");
const agent_threads = @import("../agents/agent_threads.zig");
const pane_splits = @import("pane_splits.zig");
const PaneAttachmentConfirmationType = @import("../../application/panes/PaneAttachmentConfirmation.zig");
const pane_attachments = @import("pane_attachments.zig");

pub const Outcome = enum { workspace_arrived, workspace_created, pane_split, pane_attached, ignored };

/// Consumes one correlated open continuation and delivers its confirmation.
///
/// ```zig
/// _ = try apply(client, opened);
/// ```
pub fn apply(client: *Client, opened: PaneOpenedType) !Outcome {
    const continuation = request_lifecycle.consume(client, opened.request_id) orelse
        return error.UnexpectedRequest;
    const outcome: Outcome = switch (continuation) {
        .initial_open => result: {
            try arriveWorkspace(client, translate(opened));
            break :result .workspace_arrived;
        },
        .create_workspace => |size| result: {
            try createWorkspace(client, .{ .opened = translate(opened), .requested_size = size });
            break :result .workspace_created;
        },
        .split => |split| result: {
            _ = try pane_splits.confirm(client, .{
                .requested = .{ .target_pane = split.target_pane, .location = split.location, .axis = split.axis, .area = split.area },
                .confirmed_pane = opened.pane_id,
                .confirmed_location = opened.location,
                .created = opened.created,
            });
            break :result .pane_split;
        },
        .attach_pane => |attachment| result: {
            try confirmAttachment(client, .{
                .requested = .{ .pane_id = attachment.pane_id, .location = attachment.location },
                .opened = translate(opened),
            });
            break :result .pane_attached;
        },
        .ignored => .ignored,
        else => return error.UnexpectedRequest,
    };
    if (outcome != .ignored) {
        try agent_threads.opened(client, opened);
    }

    return outcome;
}

fn translate(opened: PaneOpenedType) OpenedPaneType {
    return .{
        .pane_id = opened.pane_id,
        .location = opened.location,
        .created = opened.created,
    };
}

fn arriveWorkspace(client: *Client, opened: OpenedPaneType) !void {
    try workspace_handoffs.confirm(client, try workspace_handoffs.arrival(client, opened));
}

fn createWorkspace(client: *Client, confirmation: WorkspaceCreationType) !void {
    _ = try workspace_creations.confirm(client, workspace_creations.confirmation(
        client,
        confirmation.opened,
        confirmation.requested_size,
    ));
}

fn confirmAttachment(client: *Client, confirmation: PaneAttachmentConfirmationType) !void {
    _ = try pane_attachments.confirm(client, .{
        .requested = confirmation.requested,
        .confirmed = .{
            .pane_id = confirmation.opened.pane_id,
            .location = confirmation.opened.location,
        },
        .created = confirmation.opened.created,
    });
}
