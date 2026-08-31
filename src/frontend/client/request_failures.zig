//! Adapts rejected runtime requests to client recovery and notification use cases.

const core = @import("telar-core");
const client_application = @import("application/root.zig");
const notifications = @import("../notifications/root.zig");
const client_requests = @import("requests.zig");

const Client = @import("client.zig");
const pane_attachments = @import("pane_attachments.zig");
const pane_splits = @import("pane_splits.zig");
const tab_closures = @import("tab_closures.zig");
const workspace_handoffs = @import("workspace_handoffs.zig");
const request_failure = client_application.request_failure;
const schema = core.schema;

/// Consumes one correlated continuation and applies its failure policy. Fatal
/// directives become the client loop's existing `RuntimeRequestFailed` error.
///
/// ```zig
/// _ = try apply(client, failure);
/// ```
pub fn apply(client: *Client, failure: schema.RequestFailed) !request_failure.Outcome {
    const continuation = client.requests.take(failure.request_id) orelse
        return error.UnexpectedRequestFailure;
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

fn handler(client: *Client) request_failure.HandleRequestFailureHandler {
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
    };
}

fn recoverSplit(context: *anyopaque, split: client_requests.Split) !request_failure.SplitRecovery {
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

fn recoverAttachment(context: *anyopaque, attachment: client_requests.PaneOperation) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    var recovery = pane_attachments.recoveryHandler(client);

    _ = try recovery.execute(.{
        .pane_id = attachment.pane_id,
        .location = attachment.location,
    });
}

fn recoverCloseTab(context: *anyopaque, location: schema.TabLocation) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    var recovery = tab_closures.recoveryHandler(client);

    _ = try recovery.execute(location);
}

fn recoverInitialOpen(context: *anyopaque, failure: request_failure.InitialOpenFailure) !request_failure.InitialOpenRecovery {
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

fn publishNotification(context: *anyopaque, input: notifications.Input) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try client.notify(input);
}
