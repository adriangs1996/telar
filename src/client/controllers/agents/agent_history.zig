//! Bounded request correlation; the application handler owns reading state.
const core = @import("telar-core");
const Client = @import("../../AttachedClient.zig");
const Handler = @import("../../application/agents/AgentHistoryHandler.zig");
const lifecycle = @import("../../connection/request_lifecycle.zig");

/// Records explicit navigation without allocating or issuing provider work.
/// Example: `agent_history.navigate(client, id, .older);`
pub fn navigate(client: *Client, id: core.PaneId, direction: core.agent_history.Direction) void {
    _ = (Handler{ .model = &client.model }).navigate(id, direction);
}

/// Example: `agent_history.reverse(client, id, .newer);`
pub fn reverse(client: *Client, id: core.PaneId, direction: core.agent_history.Direction) void {
    (Handler{ .model = &client.model }).reverse(id, direction);
}

/// Example: `agent_history.anchor(client, id, resolved_scroll);`
pub fn anchor(client: *Client, id: core.PaneId, scroll: u32) void {
    (Handler{ .model = &client.model }).anchor(id, scroll);
}

/// Example: `agent_history.skipFolded(client, id);`
pub fn skipFolded(client: *Client, id: core.PaneId) void {
    _ = (Handler{ .model = &client.model }).skipFolded(id);
}

/// Example: `agent_history.revealWork(client, id);`
pub fn revealWork(client: *Client, id: core.PaneId) void {
    (Handler{ .model = &client.model }).revealWork(id);
}

/// Freezes displayed text during selection; call during preparation, never input.
/// Example: `if (try agent_history.freeze(client, id, attachment)) beginSelection();`
pub fn freeze(client: *Client, id: core.PaneId, attachment: u64) !bool {
    return (Handler{ .model = &client.model }).freeze(id, attachment);
}

/// Releases selection retention without discarding a pre-existing history reader.
/// Example: `agent_history.unfreeze(client, id, attachment);`
pub fn unfreeze(client: *Client, id: core.PaneId, attachment: u64) void {
    (Handler{ .model = &client.model }).unfreeze(id, attachment);
}

/// Starts at most one history request for this connection after frame delivery.
/// Example: `try agent_history.flush(client);`
pub fn flush(client: *Client) !void {
    if (lifecycle.has(client, .agent_history)) {
        return;
    }
    const tab = client.model.activeTabModel() orelse return;
    for (&tab.panes) |*entry| {
        const pane = if (entry.*) |*value| value else continue;
        if (pane.history_intent == null) {
            continue;
        }
        const handler: Handler = .{ .model = &client.model };
        var query = (handler.begin(pane.id) catch |err| {
            try report(client, @errorName(err));
            continue;
        }) orelse continue;
        const operation: @import("../../connection/AgentHistoryOperation.zig") = .{ .owner = .{ .pane_id = pane.id, .pane_generation = pane.pane_generation, .attachment_generation = pane.attachment_generation, .location = pane.location }, .view_generation = query.view_generation };
        query.request_id = lifecycle.nextId(client) catch |err| {
            _ = handler.failed(operation, @errorName(err));
            try report(client, @errorName(err));
            return;
        };
        lifecycle.register(client, .{ .request_id = query.request_id, .continuation = .{ .agent_history = operation } }) catch |err| {
            _ = handler.failed(operation, @errorName(err));
            try report(client, @errorName(err));
            return;
        };
        @import("../../entrypoints/runtime_io.zig").enqueueAgentHistory(client, query) catch |err| {
            _ = lifecycle.consume(client, query.request_id);
            _ = handler.failed(operation, @errorName(err));
            try report(client, @errorName(err));
            return;
        };
        return;
    }
}

/// Consumes a page response once, before receive storage can be reused.
/// Example: `_ = try agent_history.apply(client, response);`
pub fn apply(client: *Client, response: core.AgentHistoryPageView) !bool {
    const continuation = lifecycle.consume(client, response.request_id) orelse return false;
    const handler: Handler = .{ .model = &client.model };
    defer handler.retired();
    if (continuation == .ignored) {
        return false;
    }
    if (continuation != .agent_history) {
        return error.UnexpectedControlReply;
    }
    return handler.apply(continuation.agent_history, response) catch |err| {
        _ = handler.failed(continuation.agent_history, @errorName(err));
        try report(client, @errorName(err));
        return false;
    };
}

fn report(client: *Client, message: []const u8) !void {
    try @import("../notifications/notifications.zig").publishNow(client, .{ .level = .failure, .title = "Could not load messages", .message = message });
}
