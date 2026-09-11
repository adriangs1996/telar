//! Adapts rejected runtime requests to client recovery and notification use cases.

const Client = @import("../../Client.zig");
const RequestFailedType = @import("telar-core").RequestFailed;
const ApplicationSessionRequestFailureOutcome = @import("telar-client").ApplicationSessionRequestFailureOutcome;
const request_lifecycle = @import("../../connection/request_lifecycle.zig");
const HandleRequestFailureHandlerType = @import("telar-client").HandleRequestFailureHandler;
const builtin = @import("builtin");
const std = @import("std");
const SplitType = @import("telar-client").Split;
const SplitRecoveryType = @import("telar-client").SplitRecovery;
const pane_splits = @import("../panes/pane_splits.zig");
const PaneOperationType = @import("telar-client").PaneOperation;
const pane_attachments = @import("../panes/pane_attachments.zig");
const TabLocationType = @import("telar-core").TabLocation;
const tab_closures = @import("../tabs/tab_closures.zig");
const InitialOpenFailureType = @import("telar-client").InitialOpenFailure;
const InitialOpenRecoveryType = @import("telar-client").InitialOpenRecovery;
const workspace_handoffs = @import("../workspaces/workspace_handoffs.zig");
const InputType = @import("telar-client").NotificationInput;
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
    var use_case = handler(client);
    const outcome = try use_case.execute(.{
        .continuation = continuation,
        .code = failure.code,
        .message = failure.message,
    });
    if (outcome == .fatal) {
        return error.RuntimeRequestFailed;
    }

    return outcome;
}

fn handler(client: *Client) HandleRequestFailureHandlerType {
    return .{
        .recovery = .{
            .context = client,
            .split = recoverSplit,
            .attachment = recoverAttachment,
            .close_tab = recoverCloseTab,
            .initial_open = recoverInitialOpen,
        },
        .notifications = .{
            .context = client,
            .publish = publishNotification,
        },
        .reporting = .{
            .context = client,
            .report = reportFailure,
        },
    };
}

fn reportFailure(_: *anyopaque, message: []const u8) void {
    if (builtin.is_test) {
        return;
    }

    std.debug.print("telar runtime: {s}\n", .{message});
}

fn recoverSplit(context: *anyopaque, split: SplitType) !SplitRecoveryType {
    const client: *Client = @ptrCast(@alignCast(context));
    var recovery = pane_splits.recoveryHandler(client);
    const status = try recovery.execute(.{
        .target_pane = split.target_pane,
        .location = split.location,
        .axis = split.axis,
        .area = split.area,
    });

    return switch (status) {
        .restored, .not_required => .current,
        .stale => .stale,
    };
}

fn recoverAttachment(context: *anyopaque, attachment: PaneOperationType) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    var recovery = pane_attachments.recoveryHandler(client);

    _ = try recovery.execute(.{
        .pane_id = attachment.pane_id,
        .location = attachment.location,
    });
}

fn recoverCloseTab(context: *anyopaque, location: TabLocationType) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    var recovery = tab_closures.recoveryHandler(client);

    _ = try recovery.execute(location);
}

fn recoverInitialOpen(context: *anyopaque, failure: InitialOpenFailureType) !InitialOpenRecoveryType {
    const client: *Client = @ptrCast(@alignCast(context));
    var recovery = workspace_handoffs.recoveryHandler(client);
    const result = try recovery.execute(.{
        .fallback_workspace = failure.open.fallback_workspace,
        .code = failure.code,
    });

    return switch (result) {
        .retried => .retried,
        .unrecoverable => .unrecoverable,
    };
}

fn publishNotification(context: *anyopaque, input: InputType) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try notification_flow.publishNow(client, input);
}
