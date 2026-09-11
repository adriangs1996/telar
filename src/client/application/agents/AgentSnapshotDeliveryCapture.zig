const ModelType = @import("../../model/Model.zig");
const AgentSnapshotDelivery = @import("AgentSnapshotDelivery.zig");
const AgentSnapshotCommitType = @import("../../model/AgentSnapshotCommit.zig");
const DeliveryCapture = @This();

model: *const ModelType,
calls: usize = 0,
observed_commit: bool = false,
fail: bool = false,

pub fn port(capture: *DeliveryCapture) AgentSnapshotDelivery {
    return .{ .context = capture, .deliver = deliver };
}

pub fn reset(capture: *DeliveryCapture) void {
    capture.calls = 0;
    capture.observed_commit = false;
}

fn deliver(context: *anyopaque, commit: *const AgentSnapshotCommitType) !void {
    const capture: *DeliveryCapture = @ptrCast(@alignCast(context));
    capture.calls += 1;
    capture.observed_commit = capture.model.version().agents == commit.agent_revision and
        capture.model.agentSnapshot().revision == commit.runtime_revision and
        capture.model.agentSnapshot().count == commit.count and
        commit.agent_revision_before +% 1 == commit.agent_revision;

    if (capture.fail) {
        return error.AgentSnapshotDeliveryFailed;
    }
}
