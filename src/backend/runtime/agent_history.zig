//! Correlated observation reads. Live pane snapshots remain independent.
const client_connection = @import("client_connection.zig");
const core = @import("telar-core");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const Job = @import("application/AgentHistoryJob.zig");
const PendingFailure = @import("delivery/PendingFailure.zig");

/// Admits a read without retaining the client's wire buffer or a pane pointer.
/// Example: `try agent_history.start(model, client, query);`.
pub fn start(model: *RuntimeModel, client: *Session, query: core.QueryAgentHistory) !void {
    admit(model, client, query) catch |err| {
        if (client.role == .control) {
            client.delivery.setCloseAfterReply(true);
        }

        try client.delivery.responses.push(.{ .request_failed = failure(query.request_id, err) });
    };
}

fn admit(model: *RuntimeModel, client: *Session, query: core.QueryAgentHistory) !void {
    const pane = model.panes.resolve(.{ .id = query.pane_id, .generation = query.pane_generation }) orelse return error.PaneNotFound;
    if (pane.kind != .agent) {
        return error.NotAnAgentPane;
    }
    if (pane.close_requested or pane.exit != null) {
        return error.PaneExited;
    }
    if (client.delivery.responses.hasAgentHistory()) {
        return error.AgentHistoryBusy;
    }

    const slot = try model.agent_history_jobs.available(client.key);
    const snapshot = pane.agent_thread orelse return error.AgentNotReady;
    const job = &model.agent_history_jobs.storage[slot];
    job.* = try Job.init(model.gpa, .{
        .client = client.key,
        .pane = pane.key(),
        .thread_id = snapshot.threadId(),
        .options = pane.session.agent.session.history_options,
        .request = query,
    });
    errdefer job.deinit();
    model.agent_history_jobs.items[slot] = job;
    errdefer model.agent_history_jobs.items[slot] = null;
    try model.select.concurrent(.agent_history_completed, Job.run, .{ job, model.io });
}

/// Delivers only to the original client generation and validates pane reuse.
/// Example: `agent_history.finish(model, job);`.
pub fn finish(model: *RuntimeModel, job: *Job) void {
    model.agent_history_jobs.remove(job);
    defer job.deinit();
    const client = model.clients.resolve(job.client) orelse return;
    if (!client.active()) {
        return;
    }

    if (client.role == .control) {
        client.delivery.setCloseAfterReply(true);
    }

    const pane = model.panes.resolve(job.pane);
    const err: ?anyerror = if (pane == null) error.PaneNotFound else if (pane.?.close_requested or pane.?.exit != null) error.PaneExited else job.failure;
    if (err) |problem| {
        client.delivery.responses.push(.{ .request_failed = failure(job.request_id, problem) }) catch {
            client_connection.drop(model, job.client);
            return;
        };
    } else if (job.result) |result| {
        client.delivery.responses.push(.{ .agent_history_page = result }) catch {
            client_connection.drop(model, job.client);
            return;
        };
        job.result = null;
    }
}

fn failure(request_id: core.RequestId, err: anyerror) PendingFailure {
    return .{
        .request_id = request_id,
        .code = switch (err) {
            error.PaneNotFound => .pane_not_found,
            error.PaneExited => .pane_exited,
            error.NotAnAgentPane, error.InvalidHistoryCursor, error.InvalidAgentHistoryCursor => .invalid_request,
            error.AgentHistoryBusy, error.OutOfMemory, error.ProviderFrameTooLarge, error.HistoryResponseTooLarge, error.HistoryScanLimit, error.HistoryCursorTooLarge => .resource_limit,
            else => .internal,
        },
        .message = switch (err) {
            error.PaneNotFound => "agent pane no longer exists",
            error.PaneExited => "agent pane is closing",
            error.NotAnAgentPane => "pane is a terminal",
            error.AgentNotReady => "agent conversation is not ready",
            error.AgentHistoryBusy => "an agent history page is already pending",
            error.InvalidHistoryCursor, error.InvalidAgentHistoryCursor => "invalid agent history cursor",
            error.HistoryPaginationUnsupported => "this Codex session does not support history pagination",
            error.ProviderFrameTooLarge, error.HistoryResponseTooLarge => "agent history item exceeds the reader limit",
            error.HistoryCursorTooLarge => "Codex history cursor exceeds the reader limit",
            error.HistoryItemNotRepresentable => "Codex history item cannot be displayed safely",
            error.HistoryTimeout => "Codex history reader timed out",
            error.HistoryAnchorUnavailable => "conversation position is not available in persisted history yet",
            error.HistoryScanLimit => "conversation position exceeds the history search limit",
            error.ProviderHistoryRejected => "Codex rejected the history request",
            error.OutOfMemory => "agent history reader memory limit reached",
            else => "agent history could not be read",
        },
    };
}
