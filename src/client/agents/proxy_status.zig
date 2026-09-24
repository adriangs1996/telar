//! Proxy status: applies the runtime's observation proxy state.
const data = @import("model");
const core = @import("telar-core");
const std = @import("std");
const notifications = @import("../notifications/notifications.zig");
const Client = @import("../execution/Client.zig");

/// Commits one decoded proxy state and announces only semantic transitions.
pub fn applyProxyStatus(client: *Client, message: core.ProxyStatus) !?data.ProxyStatusCommit {
    const commit = data.proxy_status.reconcile(&client.model, message) orelse return null;

    const trust_only = commit.previous == commit.active and commit.previous_scope == commit.scope;
    try notifications.publishNotificationNow(
        client,
        .{
            .level = if (commit.active or commit.system_trusted) .warning else .info,
            .title = if (trust_only)
                if (commit.system_trusted) "Proxy CA trusted by system" else "Proxy CA removed from system trust"
            else if (commit.active)
                "TLS interception active"
            else
                "TLS interception stopped",
            .message = if (trust_only)
                if (commit.system_trusted) "The short-lived Telar CA is installed" else "The Telar CA is no longer installed"
            else if (commit.active)
                "Agent network traffic is being observed"
            else
                "Agent network traffic is no longer observed",
            .duration_ns = if (commit.active or commit.system_trusted)
                7 * std.time.ns_per_s
            else
                data.notifications.default_duration_ns,
        },
    );
    return commit;
}
