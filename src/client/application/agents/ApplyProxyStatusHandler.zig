const ApplyProxyStatusHandler = @This();
const client_model = @import("../../root.zig").model;
const ProxyStatusDelivery = @import("ProxyStatusDelivery.zig");
const core = @import("telar-core");
model: *client_model.Model,
delivery: ProxyStatusDelivery,

/// Commits a changed proxy state before delivering its exact transition.
/// Repeated values produce neither a commit nor a delivery.
///
/// ```zig
/// const commit = try handler.execute(.{ .active = true, .scope = .exact, .system_trusted = false }) orelse return;
/// ```
pub fn execute(handler: *ApplyProxyStatusHandler, status: core.schema.ProxyStatus) !?client_model.ProxyStatusCommit {
    const commit = handler.model.reconcileProxyStatus(status) orelse return null;

    try handler.delivery.deliver(handler.delivery.context, commit);
    return commit;
}
