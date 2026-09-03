//! Adapts runtime TLS interception state to the client application boundary.

const core = @import("telar-core");
const agents_application = @import("../../application/agents/root.zig");
const client_model = @import("../../model/root.zig");
const notifications = @import("../../../notifications/root.zig");

const Client = @import("../../client.zig");
const notification_flow = @import("../notifications/notifications.zig");
const proxy_status = agents_application.proxy_status;
const proxy_status_delivery = agents_application.proxy_status_delivery;
const schema = core.schema;

/// Commits one decoded proxy state and announces only semantic transitions.
///
/// ```zig
/// _ = try apply(client, message);
/// ```
pub fn apply(client: *Client, message: schema.ProxyStatus) !?client_model.ProxyStatusCommit {
    var use_case = handler(client);

    return use_case.execute(message);
}

fn handler(client: *Client) proxy_status.ApplyProxyStatusHandler {
    return .{
        .model = &client.model,
        .delivery = .{
            .context = client,
            .deliver = deliverCommit,
        },
    };
}

fn deliverCommit(context: *anyopaque, commit: client_model.ProxyStatusCommit) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    var use_case: proxy_status_delivery.DeliverProxyStatusHandler = .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .publish_notification = publishNotification,
        },
    };

    try use_case.execute(commit);
}

fn publishNotification(context: *anyopaque, input: notifications.Input) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try notification_flow.publishNow(client, input);
}
