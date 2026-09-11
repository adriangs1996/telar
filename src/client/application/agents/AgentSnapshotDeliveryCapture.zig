const DeliveryCapture = @This();
const client_model = @import("../../root.zig").model;
const AgentSnapshotDelivery = @import("AgentSnapshotDelivery.zig");
model: *const client_model.Model,
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

fn deliver(context: *anyopaque, commit: *const client_model.AgentSnapshotCommit) !void {
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
