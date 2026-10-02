//! Request failure: a runtime rejection releases its correlation and reports
//! or recovers the request it belonged to.
const data = @import("model");
const core = @import("telar-core");
const std = @import("std");
const builtin = @import("builtin");
const notifications = @import("../notifications/notifications.zig");
const pane_attachment = @import("../panes/pane_attachment.zig");
const pane_split = @import("../panes/pane_split.zig");
const tab_removal = @import("../workspace/tab_removal.zig");
const workspace_handoff = @import("../workspace/workspace_handoff.zig");
const Client = @import("../execution/Client.zig");

/// Recovers the correlated operation before publishing its failure notification.
pub fn failRuntimeRequest(client: *Client, failure: core.RequestFailed) !RequestFailureOutcome {
    const continuation = client.model.request_lifecycle.tracker.take(failure.request_id) orelse {
        reportRuntimeFailure(failure.message);

        return error.UnexpectedRequestFailure;
    };

    _ = client.model.editor_open.complete(failure.request_id);

    errdefer reportRuntimeFailure(failure.message);
    switch (continuation) {
        .ignored => return .ignored,
        .peek_screen => {
            client.model.peek_screen.reading = false;
            return .ignored;
        },
        .workspace_snapshot, .tab_snapshot => return error.RuntimeRequestFailed,
        .initial_open => |open| {
            const outcome = try workspace_handoff.recoverWorkspaceSwitch(&client.model, open.fallback_workspace, failure.code);
            return switch (outcome) {
                .retried => .recovered,
                .unrecoverable => error.RuntimeRequestFailed,
            };
        },
        .split => |split| {
            const outcome = try pane_split.recoverPaneSplit(
                &client.model,
                .{
                    .target_pane = split.target_pane,
                    .location = split.location,
                    .axis = split.axis,
                    .area = split.area,
                },
            );
            if (outcome == .stale) {
                return .ignored;
            }
        },
        .attach_pane => |attachment| {
            if (failure.code == .pane_not_found) {
                _ = try pane_attachment.recoverPaneAttachment(
                    &client.model,
                    .{
                        .pane_id = attachment.pane_id,
                        .location = attachment.location,
                    },
                );
            }
        },
        .close_tab => |location| {
            _ = try tab_removal.recoverTabClose(&client.model, location);
        },
        .close_pane,
        .create_workspace,
        .rename_workspace,
        .create_tab,
        .rename_tab,
        .move_tab,
        .notification,

        .editor_open,
        .peek_action,
        => {},
    }

    try notifications.publishNotificationNow(client, data.request_failure.notification(
        .{
            .continuation = continuation,
            .code = failure.code,
            .message = failure.message,
        },
    ));
    return .notified;
}

fn reportRuntimeFailure(message: []const u8) void {
    if (builtin.is_test) {
        return;
    }

    std.debug.print(
        "telar runtime: {s}\n",
        .{
            message,
        },
    );
}

const RequestFailureOutcome = enum {
    ignored,
    recovered,
    notified,
    fatal,
};
