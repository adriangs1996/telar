//! Adapts runtime TLS interception state to the client application boundary.

const std = @import("std");
const notification_capability = @import("../../notifications/notifications.zig");
const Client = @import("../../AttachedClient.zig");
const ProxyStatusType = @import("telar-core").ProxyStatus;
const ProxyStatusCommitType = @import("../../model/ProxyStatusCommit.zig");
const notification_flow = @import("../notifications/notifications.zig");

/// Commits one decoded proxy state and announces only semantic transitions.
///
/// ```zig
/// _ = try apply(client, message);
/// ```
pub fn apply(client: *Client, message: ProxyStatusType) !?ProxyStatusCommitType {
    const commit = client.model.reconcileProxyStatus(message) orelse return null;

    const trust_only = commit.previous == commit.active and commit.previous_scope == commit.scope;
    try notification_flow.publishNow(client, .{
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
            notification_capability.default_duration_ns,
    });
    return commit;
}
