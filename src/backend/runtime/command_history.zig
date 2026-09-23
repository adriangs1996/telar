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

        return client_request.fail(session, request.request_id, .resource_limit, "history queue is full");
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
        return refuse(session, request.request_id);
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
        return refuse(session, request.request_id);
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
        return refuse(session, request.request_id);
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
        return refuse(session, request.request_id);
    }
}

fn origin(session: *const Session) QueryOrigin {
    return .{ .client = session.key, .close_after_reply = session.role == .control };
}

fn refuse(session: *Session, request_id: core.RequestId) !void {
    try client_request.fail(session, request_id, .resource_limit, "history queue is full");
}
