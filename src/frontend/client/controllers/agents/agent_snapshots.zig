//! Adapts runtime agent messages to the client application boundary.

const Client = @import("../../Client.zig");
const AgentSnapshotViewType = @import("telar-core").AgentSnapshotView;
const AgentSnapshotCommitType = @import("telar-client").AgentSnapshotCommit;
const max_agent_snapshot_entries_module = @import("telar-core").max_agent_snapshot_entries;
const AgentInputType = @import("telar-client").AgentInput;
const ApplyAgentSnapshotHandlerType = @import("telar-client").ApplyAgentSnapshotHandler;
const DeliverAgentSnapshotHandlerType = @import("telar-client").DeliverAgentSnapshotHandler;
const active_pane_resources = @import("../panes/active_pane_resources.zig");
const InputType = @import("telar-client").NotificationInput;
const notification_flow = @import("../notifications/notifications.zig");
const sidebar_animations = @import("../notifications/sidebar_animations.zig");

/// Maps one validated wire view into bounded agent inputs and synchronizes
/// dependent client slices after the application handler commits it.
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
        };
        count += 1;
    }

    var use_case = handler(client);
    return use_case.execute(.{
        .revision = snapshot.revision,
        .agents = entries[0..count],
    });
}

fn handler(client: *Client) ApplyAgentSnapshotHandlerType {
    return .{
        .model = &client.model,
        .delivery = .{
            .context = client,
            .deliver = deliverCommit,
        },
    };
}

fn deliverCommit(context: *anyopaque, commit: *const AgentSnapshotCommitType) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    var use_case: DeliverAgentSnapshotHandlerType = .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .synchronize_attachments = synchronizeAttachments,
            .publish_alert = publishAlert,
            .synchronize_animation = synchronizeAnimation,
        },
    };

    try use_case.execute(commit);
}

fn synchronizeAttachments(context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    _ = try active_pane_resources.synchronizeAttachments(client);
}

fn publishAlert(context: *anyopaque, input: InputType) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try notification_flow.publishNow(client, input);
}

fn synchronizeAnimation(context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    _ = try sidebar_animations.synchronize(client);
}
