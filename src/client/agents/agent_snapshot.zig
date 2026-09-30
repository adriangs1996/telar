//! Agent snapshot: applies the runtime's view of every agent and the alerts it
//! raises.
const sidebar_animation = @import("../notifications/sidebar_animation.zig");
const data = @import("model");
const core = @import("telar-core");
const agent_snapshot_delivery = @import("agent_snapshot_delivery.zig");
const FoldedAlerts = @import("FoldedAlerts.zig");
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
            .work_tree = entry.work_tree,
            .final_message = entry.final_message,
            .plan_done = entry.plan_done,
            .plan_total = entry.plan_total,
            .plan_step = entry.plan_step,
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

    try publishAlerts(client, commit.status_changes.slice());
    _ = try sidebar_animation.synchronizeSidebarAnimation(client);
    return commit;
}

/// Raises one alert per agent that became blocked, done or failed. The
/// notification center holds `max_items`, so when more change at once the
/// first `max_items - 1` alert by themselves and the rest fold into one
/// summary: no agent goes unannounced and the batch never evicts its own
/// alerts.
fn publishAlerts(client: *Client, changes: []const data.AgentStatusChange) !void {
    var alertable: usize = 0;
    for (changes) |change| {
        if (agent_snapshot_delivery.alerts(change)) {
            alertable += 1;
        }
    }

    const individual = if (alertable > data.notifications.max_items) data.notifications.max_items - 1 else alertable;
    var published: usize = 0;
    var folded: FoldedAlerts = .{};
    const current = &client.model.agent_snapshot;
    for (changes) |change| {
        if (!agent_snapshot_delivery.alerts(change)) {
            continue;
        }

        if (published == individual) {
            folded.add(change);
            continue;
        }

        var message_buffer: agent_snapshot_delivery.MessageBuffer = undefined;
        const label = if (current.find(change.key)) |agent| agent.displayName() else core.generic_display_name;
        const alert = agent_snapshot_delivery.alertInput(change, label, &message_buffer) orelse continue;
        try notifications.publishNotificationNow(client, alert);
        published += 1;
    }

    var summary_buffer: agent_snapshot_delivery.MessageBuffer = undefined;
    const summary = folded.summaryInput(&summary_buffer) orelse return;
    try notifications.publishNotificationNow(client, summary);
}
