const DeliverProxyStatusHandler = @This();
const client_model = @import("../../root.zig").model;
const Effects = @import("ProxyStatusDeliveryEffects.zig");
const std = @import("std");
const notification_capability = @import("../../root.zig").notifications;
model: *const client_model.Model,
effects: Effects,

/// Validates one exact proxy transition before publishing its semantic
/// notification.
///
/// ```zig
/// try handler.execute(commit);
/// ```
pub fn execute(handler: *DeliverProxyStatusHandler, commit: client_model.ProxyStatusCommit) !void {
    try handler.validate(commit);

    const trust_only = commit.previous == commit.active and commit.previous_scope == commit.scope;
    try handler.effects.publish_notification(handler.effects.context, .{
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
}

fn validate(handler: *const DeliverProxyStatusHandler, commit: client_model.ProxyStatusCommit) !void {
    if (handler.model.proxyTlsActive() != commit.active or
        handler.model.proxyTlsScope() != commit.scope or
        handler.model.proxySystemTrusted() != commit.system_trusted or
        handler.model.version().proxy_status != commit.proxy_status_revision or
        (commit.previous == commit.active and commit.previous_scope == commit.scope and
            commit.previous_system_trusted == commit.system_trusted) or
        commit.proxy_status_revision_before +% 1 != commit.proxy_status_revision)
    {
        return error.StaleProxyStatusCommit;
    }
}
