//! Consumes rejected requests and calls their recovery before notifying the user.

const Client = @import("../../AttachedClient.zig");
const agent_reading = @import("../../application/agents/agent_reading.zig");
const request_failure = @import("../../application/session/request_failure.zig");
const change_review = @import("../change_review/change_review.zig");
const RequestFailedType = @import("telar-core").RequestFailed;
const ApplicationSessionRequestFailureOutcome = @import("../../application/session/request_failure.zig").Outcome;
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const builtin = @import("builtin");
const std = @import("std");
const pane_splits = @import("../panes/pane_splits.zig");
const pane_attachments = @import("../panes/pane_attachments.zig");
const tab_closures = @import("../tabs/tab_closures.zig");
const workspace_handoffs = @import("../workspaces/workspace_handoffs.zig");
const notification_flow = @import("../notifications/notifications.zig");

/// Consumes one correlated continuation and applies its failure policy. Fatal
/// directives become the client loop's existing `RuntimeRequestFailed` error.
///
/// ```zig
/// _ = try apply(client, failure);
/// ```
pub fn apply(client: *Client, failure: RequestFailedType) !ApplicationSessionRequestFailureOutcome {
    const continuation = request_lifecycle.consume(client, failure.request_id) orelse {
        reportFailure(client, failure.message);

        return error.UnexpectedRequestFailure;
    };
    if (continuation == .ignored) {
        change_review.retired(client, failure.request_id);
        agent_reading.retired(&client.model);
    }
    if (continuation == .agent_history) {
        defer agent_reading.retired(
            &client.model,
        );
        if (!agent_reading.failed(&client.model, continuation.agent_history, failure.message)) {
            return .ignored;
        }
    }
    switch (continuation) {
        .change_review_query, .change_review_command => |operation| {
            if (!change_review.failed(client, operation, failure.message)) {
                return .ignored;
            }
        },
        else => {},
    }
    _ = client.editor_open.complete(failure.request_id);

    errdefer reportFailure(client, failure.message);
    switch (continuation) {
        .ignored => return .ignored,
        .workspace_snapshot, .tab_snapshot => return error.RuntimeRequestFailed,
        .initial_open => |open| {
            const outcome = try workspace_handoffs.recover(client, .{
                .fallback_workspace = open.fallback_workspace,
                .code = failure.code,
            });
            return switch (outcome) {
                .retried => .recovered,
                .unrecoverable => error.RuntimeRequestFailed,
            };
        },
        .split => |split| {
            const outcome = try pane_splits.recover(client, .{
                .target_pane = split.target_pane,
                .location = split.location,
                .axis = split.axis,
                .area = split.area,
            });
            if (outcome == .stale) {
                return .ignored;
            }
        },
        .attach_pane => |attachment| {
            if (failure.code == .pane_not_found) {
                _ = try pane_attachments.recover(client, .{ .pane_id = attachment.pane_id, .location = attachment.location });
            }
        },
        .close_tab => |location| {
            _ = try tab_closures.recover(client, location);
        },
        .close_pane,
        .create_workspace,
        .rename_workspace,
        .create_tab,
        .rename_tab,
        .move_tab,
        .notification,
        .agent_prompt,
        .agent_control,
        .agent_query,
        .agent_history,
        .change_review_query,
        .change_review_command,
        .editor_open,
        => {},
    }

    try notification_flow.publishNow(client, request_failure.notification(.{
        .continuation = continuation,
        .code = failure.code,
        .message = failure.message,
    }));
    return .notified;
}

fn reportFailure(_: *Client, message: []const u8) void {
    if (builtin.is_test) {
        return;
    }

    std.debug.print("telar runtime: {s}\n", .{message});
}
