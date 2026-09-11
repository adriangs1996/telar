const DeliverAgentSnapshotHandler = @This();
const client_model = @import("../../root.zig").model;
const Effects = @import("AgentSnapshotDeliveryEffects.zig");
const notification_capability = @import("../../root.zig").notifications;
const core = @import("telar-core");
const source_namespace = @import("agent_snapshot_delivery.zig");
const std = @import("std");
model: *const client_model.Model,
effects: Effects,

/// Validates one exact commit before synchronizing attachments, publishing
/// bounded actionable alerts and reconciling sidebar animation in order.
///
/// ```zig
/// try handler.execute(&commit);
/// ```
pub fn execute(handler: *DeliverAgentSnapshotHandler, commit: *const client_model.AgentSnapshotCommit) !void {
    try handler.validate(commit);
    try handler.effects.synchronize_attachments(handler.effects.context);

    var alert_count: usize = 0;
    const snapshot = handler.model.agentSnapshot();
    for (commit.status_changes.slice()) |change| {
        if (alert_count == notification_capability.max_items) {
            break;
        }

        var message_buffer: [96]u8 = undefined;
        const label = if (snapshot.find(change.key)) |agent| agent.displayName() else core.agent_manifest.generic_display_name;
        const alert = source_namespace.alertInput(change, label, &message_buffer) orelse continue;

        try handler.effects.publish_alert(handler.effects.context, alert);
        alert_count += 1;
    }

    try handler.effects.synchronize_animation(handler.effects.context);
}

fn validate(handler: *const DeliverAgentSnapshotHandler, commit: *const client_model.AgentSnapshotCommit) !void {
    const snapshot = handler.model.agentSnapshot();
    const change_count: usize = commit.status_changes.count;
    if (snapshot.revision != commit.runtime_revision or
        @as(usize, snapshot.count) != commit.count or
        handler.model.version().agents != commit.agent_revision or
        commit.agent_revision_before +% 1 != commit.agent_revision or
        change_count > commit.status_changes.items.len or
        change_count > commit.count)
    {
        return error.StaleAgentSnapshotCommit;
    }

    const changes = commit.status_changes.items[0..change_count];
    for (changes, 0..) |change, index| {
        const agent = snapshot.find(change.key) orelse return error.StaleAgentSnapshotCommit;
        if (agent.pane_index != change.pane_index or
            agent.provider != change.provider or
            agent.status != change.current or
            change.previous == change.current)
        {
            return error.StaleAgentSnapshotCommit;
        }

        for (changes[0..index]) |previous| {
            if (std.meta.eql(previous.key, change.key)) {
                return error.StaleAgentSnapshotCommit;
            }
        }
    }
}
