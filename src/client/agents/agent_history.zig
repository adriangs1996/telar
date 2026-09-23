//! Agent history: reads an agent's conversation pages from the runtime.
const data = @import("model");
const core = @import("telar-core");
const agent_reading = @import("agent_reading.zig");
const notifications = @import("../notifications/notifications.zig");
const Client = @import("../execution/Client.zig");

/// Starts at most one history request for this connection after frame delivery.
/// Example: `try agent_history.flushAgentHistory(app);`
pub fn flushAgentHistory(client: *Client) !void {
    if (client.model.request_lifecycle.tracker.has(.agent_history)) {
        return;
    }

    const tab = client.model.tabs.activeSlot() orelse return;
    var panes = client.model.panes.iterate(client.model.tabs.location[tab].tab_id);
    while (panes.next()) |pane| {
        if (pane.history_intent == null) {
            continue;
        }

        var query = (agent_reading.begin(&client.model, pane.id) catch |err| {
            try reportAgentHistoryFailure(client, @errorName(err));
            continue;
        }) orelse continue;
        const operation: data.AgentHistoryOperation = .{
            .owner = .{
                .pane_id = pane.id,
                .pane_generation = pane.pane_generation,
                .attachment_generation = pane.attachment_generation,
                .location = pane.location,
            },
            .view_generation = query.view_generation,
        };

        query.request_id = client.model.request_lifecycle.nextId() catch |err| {
            _ = agent_reading.failed(
                &client.model,
                operation,
                @errorName(err),
            );
            try reportAgentHistoryFailure(client, @errorName(err));
            return;
        };

        client.model.request_lifecycle.tracker.add(
            query.request_id,
            .{
                .agent_history = operation,
            },
        ) catch |err| {
            _ = agent_reading.failed(
                &client.model,
                operation,
                @errorName(err),
            );
            try reportAgentHistoryFailure(client, @errorName(err));
            return;
        };

        sendRuntimeAgentHistory(&client.model, query) catch |err| {
            _ = client.model.request_lifecycle.tracker.take(query.request_id);
            _ = agent_reading.failed(
                &client.model,
                operation,
                @errorName(err),
            );
            try reportAgentHistoryFailure(client, @errorName(err));
            return;
        };

        return;
    }
}

/// Copies a page cursor before its reading window can change.
/// Example: `try agent_history.sendRuntimeAgentHistory(client, request);`
fn sendRuntimeAgentHistory(model: *data.ClientModel, request: core.QueryAgentHistory) !void {
    try model.to_runtime.pushAgentHistory(request);
}

/// Consumes a page response once, before receive storage can be reused.
pub fn applyAgentHistory(client: *Client, response: core.AgentHistoryPageView) !bool {
    const continuation = client.model.request_lifecycle.tracker.take(response.request_id) orelse return false;

    defer agent_reading.retired(&client.model);
    if (continuation == .ignored) {
        return false;
    }

    if (continuation != .agent_history) {
        return error.UnexpectedControlReply;
    }

    return agent_reading.apply(
        &client.model,
        continuation.agent_history,
        response,
    ) catch |err| {
        _ = agent_reading.failed(
            &client.model,
            continuation.agent_history,
            @errorName(err),
        );
        try reportAgentHistoryFailure(client, @errorName(err));
        return false;
    };
}

fn reportAgentHistoryFailure(client: *Client, message: []const u8) !void {
    try notifications.publishNotificationNow(
        client,
        .{
            .level = .failure,
            .title = "Could not load messages",
            .message = message,
        },
    );
}
