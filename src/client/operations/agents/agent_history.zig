//! Correlates runtime history pages with the client-owned reading window.
const core = @import("telar-core");
const Client = @import("../../AttachedClient.zig");
const reading = @import("../../application/agents/agent_reading.zig");
const AgentHistoryOperation = @import("../../connection/AgentHistoryOperation.zig");
const notifications = @import("../notifications/notifications.zig");

pub const navigate = reading.navigate;
pub const reverse = reading.reverse;
pub const anchor = reading.anchor;
pub const skipFolded = reading.skipFolded;
pub const prefetch = reading.prefetch;
pub const revealWork = reading.revealWork;
pub const freeze = reading.freeze;
pub const unfreeze = reading.unfreeze;

/// Starts at most one history request for this connection after frame delivery.
/// Example: `try agent_history.flush(client);`
pub fn flush(client: *Client) !void {
    if (client.request_lifecycle.tracker.has(.agent_history)) {
        return;
    }
    const tab = client.model.activeTabModel() orelse return;
    var panes = tab.paneIterator();
    while (panes.next()) |pane| {
        if (pane.history_intent == null) {
            continue;
        }

        var query = (reading.begin(&client.model, pane.id) catch |err| {
            try report(client, @errorName(err));
            continue;
        }) orelse continue;
        const operation: AgentHistoryOperation = .{ .owner = .{ .pane_id = pane.id, .pane_generation = pane.pane_generation, .attachment_generation = pane.attachment_generation, .location = pane.location }, .view_generation = query.view_generation };
        query.request_id = client.request_lifecycle.nextId() catch |err| {
            _ = reading.failed(&client.model, operation, @errorName(err));
            try report(client, @errorName(err));
            return;
        };
        client.request_lifecycle.tracker.add(
            query.request_id,
            .{
                .agent_history = operation,
            },
        ) catch |err| {
            _ = reading.failed(&client.model, operation, @errorName(err));
            try report(client, @errorName(err));
            return;
        };
        client.sendRuntimeAgentHistory(query) catch |err| {
            _ = client.request_lifecycle.tracker.take(query.request_id);
            _ = reading.failed(&client.model, operation, @errorName(err));
            try report(client, @errorName(err));
            return;
        };
        return;
    }
}

/// Consumes a page response once, before receive storage can be reused.
/// Example: `_ = try agent_history.apply(client, response);`
pub fn apply(client: *Client, response: core.AgentHistoryPageView) !bool {
    const continuation = client.request_lifecycle.tracker.take(response.request_id) orelse return false;

    defer reading.retired(&client.model);
    if (continuation == .ignored) {
        return false;
    }
    if (continuation != .agent_history) {
        return error.UnexpectedControlReply;
    }
    return reading.apply(&client.model, continuation.agent_history, response) catch |err| {
        _ = reading.failed(&client.model, continuation.agent_history, @errorName(err));
        try report(client, @errorName(err));
        return false;
    };
}

fn report(client: *Client, message: []const u8) !void {
    try notifications.publishNow(client, .{ .level = .failure, .title = "Could not load messages", .message = message });
}
