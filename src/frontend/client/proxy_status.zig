//! Adapts runtime TLS interception state to the client application boundary.

const std = @import("std");
const core = @import("telar-core");
const client_application = @import("application/root.zig");
const client_model = @import("model.zig");
const notifications = @import("../notifications/root.zig");

const Client = @import("client.zig");
const proxy_status = client_application.proxy_status;
const schema = core.schema;

/// Commits one decoded proxy state and announces only semantic transitions.
///
/// ```zig
/// _ = try apply(client, message);
/// ```
pub fn apply(client: *Client, message: schema.ProxyStatus) !?client_model.ProxyStatusCommit {
    var use_case = handler(client);

    return use_case.execute(message.active);
}

fn handler(client: *Client) proxy_status.ApplyProxyStatusHandler {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .announce = announce,
        },
    };
}

fn announce(context: *anyopaque, commit: client_model.ProxyStatusCommit) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try client.notify(.{
        .level = if (commit.active) .warning else .info,
        .title = if (commit.active) "TLS interception active" else "TLS interception stopped",
        .message = if (commit.active)
            "Agent network traffic is being observed"
        else
            "Agent network traffic is no longer observed",
        .duration_ns = if (commit.active)
            7 * std.time.ns_per_s
        else
            notifications.default_duration_ns,
    });
}
