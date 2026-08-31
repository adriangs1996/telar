//! Correlates successful pane-open responses with the client operation that
//! requested them and delivers one translated confirmation.

const core = @import("telar-core");

const Client = @import("client.zig");
const pane_attachments = @import("pane_attachments.zig");
const pane_splits = @import("pane_splits.zig");
const request_lifecycle = @import("request_lifecycle.zig");
const workspace_creations = @import("workspace_creations.zig");
const workspace_handoffs = @import("workspace_handoffs.zig");
const schema = core.schema;

pub const Outcome = enum {
    workspace_arrived,
    workspace_created,
    pane_split,
    pane_attached,
    ignored,
};

/// Consumes one correlated open continuation and delivers its confirmation.
///
/// ```zig
/// _ = try apply(client, opened);
/// ```
pub fn apply(client: *Client, opened: schema.PaneOpened) !Outcome {
    const continuation = request_lifecycle.consume(client, opened.request_id) orelse
        return error.UnexpectedRequest;

    switch (continuation) {
        .initial_open => {
            var use_case = workspace_handoffs.confirmationHandler(client);
            try use_case.execute(try workspace_handoffs.arrival(client, opened));
            return .workspace_arrived;
        },
        .create_workspace => |requested_size| {
            var use_case = workspace_creations.confirmationHandler(client);
            _ = try use_case.execute(workspace_creations.confirmation(client, opened, requested_size));
            return .workspace_created;
        },
        .split => |split| {
            var use_case = pane_splits.confirmationHandler(client);
            _ = try use_case.execute(.{
                .requested = .{
                    .target_pane = split.target_pane,
                    .location = split.location,
                    .axis = split.axis,
                    .area = split.area,
                },
                .confirmed_pane = opened.pane_id,
                .confirmed_location = opened.location,
                .created = opened.created,
            });
            return .pane_split;
        },
        .attach_pane => |attachment| {
            var use_case = pane_attachments.confirmationHandler(client);
            _ = try use_case.execute(.{
                .requested = .{
                    .pane_id = attachment.pane_id,
                    .location = attachment.location,
                },
                .confirmed = .{
                    .pane_id = opened.pane_id,
                    .location = opened.location,
                },
                .created = opened.created,
            });
            return .pane_attached;
        },
        .ignored => return .ignored,
        else => return error.UnexpectedRequest,
    }
}
