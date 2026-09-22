//! Adapts runtime agent messages to the client application boundary.

const notification_capability = @import("../../notifications/notifications.zig");
const generic_display_name = @import("telar-core").generic_display_name;
const agent_snapshot_delivery = @import("../../application/agents/agent_snapshot_delivery.zig");
const Client = @import("../../AttachedClient.zig");
const AgentSnapshotViewType = @import("telar-core").AgentSnapshotView;
const AgentSnapshotCommitType = @import("../../model/AgentSnapshotCommit.zig");
const max_agent_snapshot_entries_module = @import("telar-core").max_agent_snapshot_entries;
const AgentInputType = @import("../../agents/AgentInput.zig");
const notification_flow = @import("../notifications/notifications.zig");
const sidebar_animations = @import("../notifications/sidebar_animations.zig");

/// Maps one validated wire view into bounded agent inputs and synchronizes
/// dependent client state after committing the canonical revision.
///
/// ```zig
/// _ = try apply(client, snapshot);
/// ```
pub fn apply(client: *Client, snapshot: AgentSnapshotViewType) !?AgentSnapshotCommitType {
    var entries: [max_agent_snapshot_entries_module]AgentInputType = undefined;
    var count: usize = 0;
    var iterator = snapshot.entries();
    while (try iterator.next()) |entry| {
        entries[count] = .{
            .key = .{
                .pane_id = entry.pane_id,
                .pane_generation = entry.pane_generation,
            },
            .location = entry.location,
            .pane_index = entry.pane_index,
            .workspace_label = entry.workspace_label,
            .tab_label = entry.tab_label,
            .session_title = entry.session_title,
            .title_source = entry.title_source,
            .title_state = entry.title_state,
            .cwd_label = entry.cwd_label,
            .provider = entry.provider,
            .provider_name = entry.provider_name,
            .display_name = entry.display_name,
            .icon = entry.icon,
            .attachments = entry.attachments,
            .status = entry.status,
            .blocked_reason = entry.blocked_reason,
            .last_event = entry.last_event,
            .status_age_s = entry.status_age_s,
        };
        count += 1;
    }

    const commit = try client.model.reconcileAgentSnapshot(.{
        .revision = snapshot.revision,
        .agents = entries[0..count],
    }) orelse return null;
    _ = try client.synchronizePaneAttachments();

    var alert_count: usize = 0;
    const current = client.model.agentSnapshot();
    for (commit.status_changes.slice()) |change| {
        if (alert_count == notification_capability.max_items) {
            break;
        }
        var message_buffer: [96]u8 = undefined;
        const label = if (current.find(change.key)) |agent| agent.displayName() else generic_display_name;
        const alert = agent_snapshot_delivery.alertInput(change, label, &message_buffer) orelse continue;
        try notification_flow.publishNow(client, alert);
        alert_count += 1;
    }

    _ = try sidebar_animations.synchronize(client);
    return commit;
}
