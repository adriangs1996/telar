const ModelType = @import("../../model/Model.zig");
const ProxyStatusDelivery = @import("ProxyStatusDelivery.zig");
const ProxyStatusType = @import("telar-core").ProxyStatus;
const ProxyStatusCommitType = @import("../../model/ProxyStatusCommit.zig");
const ApplyProxyStatusHandler = @This();

model: *ModelType,
delivery: ProxyStatusDelivery,

/// Commits a changed proxy state before delivering its exact transition.
/// Repeated values produce neither a commit nor a delivery.
///
/// ```zig
/// const commit = try handler.execute(.{ .active = true, .scope = .exact, .system_trusted = false }) orelse return;
/// ```
pub fn execute(handler: *ApplyProxyStatusHandler, status: ProxyStatusType) !?ProxyStatusCommitType {
    const commit = handler.model.reconcileProxyStatus(status) orelse return null;

    try handler.delivery.deliver(handler.delivery.context, commit);
    return commit;
}
