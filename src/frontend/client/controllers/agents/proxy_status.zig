//! Adapts runtime TLS interception state to the client application boundary.

const Client = @import("../../Client.zig");
const ProxyStatusType = @import("telar-core").ProxyStatus;
const ProxyStatusCommitType = @import("telar-client").ProxyStatusCommit;
const ApplyProxyStatusHandlerType = @import("telar-client").ApplyProxyStatusHandler;
const DeliverProxyStatusHandlerType = @import("telar-client").DeliverProxyStatusHandler;
const InputType = @import("telar-client").NotificationInput;
const notification_flow = @import("../notifications/notifications.zig");

/// Commits one decoded proxy state and announces only semantic transitions.
///
/// ```zig
/// _ = try apply(client, message);
/// ```
pub fn apply(client: *Client, message: ProxyStatusType) !?ProxyStatusCommitType {
    var use_case = handler(client);

    return use_case.execute(message);
}

fn handler(client: *Client) ApplyProxyStatusHandlerType {
    return .{
        .model = &client.model,
        .delivery = .{
            .context = client,
            .deliver = deliverCommit,
        },
    };
}

fn deliverCommit(context: *anyopaque, commit: ProxyStatusCommitType) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    var use_case: DeliverProxyStatusHandlerType = .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .publish_notification = publishNotification,
        },
    };

    try use_case.execute(commit);
}

fn publishNotification(context: *anyopaque, input: InputType) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try notification_flow.publishNow(client, input);
}
