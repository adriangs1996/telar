//! Adapts runtime agent messages to the client application boundary.

const core = @import("telar-core");
const agents = @import("../../../agents/root.zig");
const active_pane_resources = @import("../panes/active_pane_resources.zig");
const agents_application = @import("../../application/agents/root.zig");
const client_model = @import("../../model.zig");
const notifications = @import("../../../notifications/root.zig");
const notification_flow = @import("../notifications/notifications.zig");
const sidebar_animations = @import("../notifications/sidebar_animations.zig");

const Client = @import("../../client.zig");
const agent_snapshot = agents_application.agent_snapshot;
const agent_snapshot_delivery = agents_application.agent_snapshot_delivery;
const schema = core.schema;

/// Maps one validated wire view into bounded agent inputs and synchronizes
/// dependent client slices after the application handler commits it.
///
/// ```zig
/// _ = try apply(client, snapshot);
/// ```
pub fn apply(client: *Client, snapshot: schema.AgentSnapshotView) !?client_model.AgentSnapshotCommit {
    var entries: [schema.max_agent_snapshot_entries]agents.AgentInput = undefined;
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

fn handler(client: *Client) agent_snapshot.ApplyAgentSnapshotHandler {
    return .{
        .model = &client.model,
        .delivery = .{
            .context = client,
            .deliver = deliverCommit,
        },
    };
}

fn deliverCommit(context: *anyopaque, commit: *const client_model.AgentSnapshotCommit) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    var use_case: agent_snapshot_delivery.DeliverAgentSnapshotHandler = .{
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

fn publishAlert(context: *anyopaque, input: notifications.Input) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    try notification_flow.publishNow(client, input);
}

fn synchronizeAnimation(context: *anyopaque) !void {
    const client: *Client = @ptrCast(@alignCast(context));

    _ = try sidebar_animations.synchronize(client);
}
