//! Clients query, import, prune and inspect command history. Requests queue
//! on the history worker; its responses return through `receive`.

const core = @import("telar-core");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");
const QueryOrigin = @import("../history/QueryOrigin.zig");
const Query = @import("../history/Query.zig");
const Prune = @import("../history/Prune.zig");
const StatsQuery = @import("../history/StatsQuery.zig");
const client_request = @import("client_request.zig");
const limit_reached = @import("limit_reached.zig");
const channel_support = @import("../history/channel_support.zig");
const Sources = @import("Sources.zig");
const history_model = @import("../history/model.zig");
const QueryResult = @import("../history/QueryResult.zig");
const OutputResult = @import("../history/OutputResult.zig");
const StatsResult = @import("../history/StatsResult.zig");

/// Queues one history search for the history worker.
///
/// ```zig
/// try command_history.query(model, session, request);
/// ```
pub fn query(model: *RuntimeModel, session: *Session, request: core.QueryHistory) !void {
    const search = Query.init(.{
        .request_id = request.request_id,
        .origin = origin(session),
        .text = request.query,
        .scope = request.scope,
        .scope_value = request.scope_value,
        .pane_id = request.pane_id,
        .failed_only = request.failed_only,
        .author = request.author,
        .match = request.match,
        .distinct = request.distinct,
        .limit = request.limit,
        .offset = request.offset,
        .snapshot_id = request.snapshot_id,
        .entry_id = request.entry_id,
    }) catch {
        return client_request.fail(session, request.request_id, .invalid_request, "invalid history query");
    };

    if (!model.resources.history.service().query(model.io, search)) {
        if (comptime core.enabled) {
            model.metrics.history_query_failures += 1;
        }

        return refuse(model, session, request.request_id);
    }

    if (comptime core.enabled) {
        model.metrics.history_queries += 1;
    }
}

/// Queues a batch of imported commands.
///
/// ```zig
/// try command_history.importBatch(model, session, batch);
/// ```
pub fn importBatch(model: *RuntimeModel, session: *Session, batch: core.ImportHistoryView) !void {
    if (!model.resources.history.service().importBatch(model.io, batch)) {
        limit_reached.report(model, .{
            .limit = channel_support.requests_limit,
        });
        return client_request.fail(session, batch.request_id, .resource_limit, "history import was not accepted");
    }

    try client_request.complete(session, batch.request_id);
}

/// Queues the deletion of one history entry.
///
/// ```zig
/// try command_history.remove(model, session, request);
/// ```
pub fn remove(model: *RuntimeModel, session: *Session, request: core.DeleteHistory) !void {
    if (!model.resources.history.service().deleteHistory(model.io, .{
        .request_id = request.request_id,
        .origin = origin(session),
        .id = request.id,
    })) {
        return refuse(model, session, request.request_id);
    }
}

/// Queues the removal of every entry matching a scope.
///
/// ```zig
/// try command_history.prune(model, session, request);
/// ```
pub fn prune(model: *RuntimeModel, session: *Session, request: core.PruneHistory) !void {
    const scoped = Prune.init(.{
        .request_id = request.request_id,
        .origin = origin(session),
        .scope = request.scope,
        .scope_value = request.scope_value,
        .pane_id = request.pane_id,
        .before_ms = request.before_ms,
        .failed_only = request.failed_only,
        .match = request.match,
    }) catch {
        return client_request.fail(session, request.request_id, .invalid_request, "invalid history prune");
    };

    if (!model.resources.history.service().pruneHistory(model.io, scoped)) {
        return refuse(model, session, request.request_id);
    }
}

/// Queues a read of one entry's retained output.
///
/// ```zig
/// try command_history.readOutput(model, session, request);
/// ```
pub fn readOutput(model: *RuntimeModel, session: *Session, request: core.ReadHistoryOutput) !void {
    if (!model.resources.history.service().readOutput(model.io, .{
        .request_id = request.request_id,
        .origin = origin(session),
        .id = request.id,
    })) {
        return refuse(model, session, request.request_id);
    }
}

/// Queues aggregate statistics over a scope.
///
/// ```zig
/// try command_history.stats(model, session, request);
/// ```
pub fn stats(model: *RuntimeModel, session: *Session, request: core.HistoryStatsQuery) !void {
    const scoped = StatsQuery.init(.{
        .request_id = request.request_id,
        .origin = origin(session),
        .scope = request.scope,
        .scope_value = request.scope_value,
        .pane_id = request.pane_id,
        .since_ms = request.since_ms,
    }) catch {
        return client_request.fail(session, request.request_id, .invalid_request, "invalid history stats query");
    };

    if (!model.resources.history.service().statsHistory(model.io, scoped)) {
        return refuse(model, session, request.request_id);
    }
}

/// Rearms the history receive and moves one worker response into the queue
/// of the client that asked, which then owns any result buffers.
///
/// ```zig
/// try command_history.receive(model, result);
/// ```
pub fn receive(model: *RuntimeModel, result: anyerror!history_model.Response) !void {
    const response = result catch return;
    var owned_query: ?*QueryResult = switch (response) {
        .query_result => |value| value,
        else => null,
    };
    defer if (owned_query) |value| {
        value.deinit();
    };
    var owned_output: ?*OutputResult = switch (response) {
        .output_result => |value| value,
        else => null,
    };
    defer if (owned_output) |value| {
        value.deinit();
    };
    var owned_stats: ?*StatsResult = switch (response) {
        .stats_result => |value| value,
        else => null,
    };
    defer if (owned_stats) |value| {
        value.deinit();
    };

    var sources = Sources.init(model.io, model.select);
    try sources.receiveHistory(model.resources.history.service());

    switch (response) {
        .query_result => |value| {
            const session = model.clients.resolve(value.origin.client) orelse return;
            session.delivery.setCloseAfterReply(value.origin.close_after_reply);
            owned_query = null;
            session.delivery.responses.push(.{ .history_result = value }) catch value.deinit();
        },
        .failed => |failure| {
            const session = model.clients.resolve(failure.origin.client) orelse return;
            session.delivery.setCloseAfterReply(failure.origin.close_after_reply);
            client_request.fail(session, failure.request_id, .internal, failure.message) catch {};
        },
        .pruned => |pruned| {
            const session = model.clients.resolve(pruned.origin.client) orelse return;
            session.delivery.setCloseAfterReply(pruned.origin.close_after_reply);
            session.delivery.responses.push(.{ .history_pruned = .{
                .request_id = pruned.request_id,
                .removed = pruned.removed,
            } }) catch {};
        },
        .output_result => |value| {
            const session = model.clients.resolve(value.origin.client) orelse return;
            session.delivery.setCloseAfterReply(value.origin.close_after_reply);
            session.delivery.responses.push(.{ .history_output = value }) catch return;
            owned_output = null;
        },
        .stats_result => |value| {
            const session = model.clients.resolve(value.origin.client) orelse return;
            session.delivery.setCloseAfterReply(value.origin.close_after_reply);
            session.delivery.responses.push(.{ .history_stats = value }) catch return;
            owned_stats = null;
        },
    }
}

fn origin(session: *const Session) QueryOrigin {
    return .{ .client = session.key, .close_after_reply = session.role == .control };
}

/// Answers a request the full history queue refused, and reports the queue.
fn refuse(model: *RuntimeModel, session: *Session, request_id: core.RequestId) !void {
    limit_reached.report(model, .{
        .limit = channel_support.requests_limit,
    });
    try client_request.fail(session, request_id, .resource_limit, "history queue is full");
}
