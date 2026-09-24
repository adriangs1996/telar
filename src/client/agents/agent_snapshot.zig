//! Agent snapshot: applies the runtime's view of every agent and the alerts it
//! raises.
const sidebar_animation = @import("../notifications/sidebar_animation.zig");
const data = @import("model");
const core = @import("telar-core");
const agent_snapshot_delivery = @import("agent_snapshot_delivery.zig");
const notifications = @import("../notifications/notifications.zig");
const pane_attachment = @import("../panes/pane_attachment.zig");
const Client = @import("../execution/Client.zig");

/// Maps one validated wire view into bounded agent inputs and synchronizes
/// dependent client state after committing the canonical revision.
pub fn applyAgentSnapshot(client: *Client, snapshot: core.AgentSnapshotView) !?data.AgentSnapshotCommit {
    var entries: [core.max_agent_snapshot_entries]data.AgentInput = undefined;
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

    const commit = try data.agent_snapshot.reconcile(&client.model, 
        .{
            .revision = snapshot.revision,
            .agents = entries[0..count],
        },
    ) orelse return null;
    _ = try pane_attachment.synchronizePaneAttachments(client);

    var alert_count: usize = 0;
    const current = &client.model.agent_snapshot;
    for (commit.status_changes.slice()) |change| {
        if (alert_count == data.notifications.max_items) {
            break;
        }

        var message_buffer: [96]u8 = undefined;
        const label = if (current.find(change.key)) |agent| agent.displayName() else core.generic_display_name;
        const alert = agent_snapshot_delivery.alertInput(
            change,
            label,
            &message_buffer,
        ) orelse continue;
        try notifications.publishNotificationNow(client, alert);
        alert_count += 1;
    }

    _ = try sidebar_animation.synchronizeSidebarAnimation(client);
    return commit;
}
