const ModelType = @import("../../model/Model.zig");
const AgentSnapshotDelivery = @import("AgentSnapshotDelivery.zig");
const SnapshotInputType = @import("../../agents/SnapshotInput.zig");
const AgentSnapshotCommitType = @import("../../model/AgentSnapshotCommit.zig");
const ApplyAgentSnapshotHandler = @This();

model: *ModelType,
delivery: AgentSnapshotDelivery,

/// Commits one newer replica before delivering its exact result. Stale
/// snapshots and rejected candidates never cross the delivery boundary.
///
/// ```zig
/// const commit = try handler.execute(snapshot) orelse return;
/// ```
pub fn execute(handler: *ApplyAgentSnapshotHandler, snapshot: SnapshotInputType) !?AgentSnapshotCommitType {
    const commit = try handler.model.reconcileAgentSnapshot(snapshot) orelse return null;
    try handler.delivery.deliver(handler.delivery.context, &commit);

    return commit;
}
