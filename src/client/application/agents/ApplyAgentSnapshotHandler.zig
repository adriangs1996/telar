const ApplyAgentSnapshotHandler = @This();
const client_model = @import("../../root.zig").model;
const AgentSnapshotDelivery = @import("AgentSnapshotDelivery.zig");
const agents = @import("../../root.zig").agents;
model: *client_model.Model,
delivery: AgentSnapshotDelivery,

/// Commits one newer replica before delivering its exact result. Stale
/// snapshots and rejected candidates never cross the delivery boundary.
///
/// ```zig
/// const commit = try handler.execute(snapshot) orelse return;
/// ```
pub fn execute(handler: *ApplyAgentSnapshotHandler, snapshot: agents.SnapshotInput) !?client_model.AgentSnapshotCommit {
    const commit = try handler.model.reconcileAgentSnapshot(snapshot) orelse return null;
    try handler.delivery.deliver(handler.delivery.context, &commit);

    return commit;
}
