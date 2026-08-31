//! Adapts runtime agent messages to the client application boundary.

const std = @import("std");
const core = @import("telar-core");
const agents = @import("../agents/root.zig");
const client_application = @import("application/root.zig");
const client_model = @import("model.zig");
const attachment_targets = @import("attachment_targets.zig");
const notifications = @import("../notifications/root.zig");

const Client = @import("client.zig");
const agent_snapshot = client_application.agent_snapshot;
const schema = core.schema;

/// Maps one validated wire view into bounded agent inputs, commits it through
/// the application handler and keeps animation scheduling outside the use case.
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
    const commit = try use_case.execute(.{
        .revision = snapshot.revision,
        .agents = entries[0..count],
    });
    try client.scheduleSidebarAnimation();

    return commit;
}

fn handler(client: *Client) agent_snapshot.ApplyAgentSnapshotHandler {
    return .{
        .model = &client.model,
        .effects = .{
            .context = client,
            .reconcile = reconcile,
            .alert = alert,
            .alert_limit = notifications.max_items,
        },
    };
}

fn reconcile(context: *anyopaque, commit: *const client_model.AgentSnapshotCommit) !void {
    _ = commit;
    const client: *Client = @ptrCast(@alignCast(context));

    _ = try attachment_targets.sync(client);
}

fn alert(context: *anyopaque, change: client_model.AgentStatusChange) !void {
    const client: *Client = @ptrCast(@alignCast(context));
    var message_buffer: [64]u8 = undefined;
    const message = std.fmt.bufPrint(
        &message_buffer,
        "{s} in pane {d} is {s}",
        .{ providerName(change.provider), change.pane_index, statusName(change.current) },
    ) catch "Agent status changed";

    try client.notify(.{
        .level = switch (change.current) {
            .blocked => .warning,
            .ready => .success,
            .failed => .failure,
            .unknown, .working => unreachable,
        },
        .title = switch (change.current) {
            .blocked => "Agent needs input",
            .ready => "Agent ready",
            .failed => "Agent failed",
            .unknown, .working => unreachable,
        },
        .message = message,
        .target = .{ .focus_pane = change.key.pane_id },
        .duration_ns = if (change.current == .failed)
            7 * std.time.ns_per_s
        else
            notifications.default_duration_ns,
    });
}

fn providerName(provider: schema.AgentProvider) []const u8 {
    return switch (provider) {
        .unknown => "Agent",
        .claude => "Claude",
        .codex => "Codex",
    };
}

fn statusName(status: schema.AgentStatus) []const u8 {
    return switch (status) {
        .blocked => "waiting for input",
        .ready => "ready",
        .failed => "failed",
        .unknown, .working => "active",
    };
}
